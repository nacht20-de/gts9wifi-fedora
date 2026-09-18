/*
 * gts9wifi-autofocus — contrast-detection autofocus for the Samsung Galaxy
 * Tab S9 Wi-Fi (gts9wifi) rear camera.
 *
 * The HI1337 sensor's DW9808 VCM lens is exposed only as a manual
 * V4L2_CID_FOCUS_ABSOLUTE control (0..1023) on /dev/v4l-subdev31.  No
 * component in the stack implements autofocus: the kernel driver exposes no
 * V4L2 autofocus controls, libcamera's simple pipeline has no lens support
 * and its software IPA has no AF algorithm, so camera applications
 * (Snapshot, qcam, Megapixels) never move the lens by themselves.
 *
 * This tool closes the loop in userspace: it streams the raw sensor, sweeps
 * and refines the lens position while measuring an edge-energy focus value,
 * and leaves the lens at the sharpest position found.
 *
 * Build:
 *   gcc -O2 -o gts9wifi-autofocus gts9wifi-autofocus.c
 *
 * Use (the camera must be free — stop Snapshot and, if needed,
 * `systemctl --user restart wireplumber` first):
 *   ./gts9wifi-autofocus            # find and apply best focus
 *   ./gts9wifi-autofocus -p 512     # just set the lens position
 *   ./gts9wifi-autofocus -g 64 -e 3260
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define DEV_VIDEO  "/dev/video0"
#define DEV_LENS   "/dev/v4l-subdev31"
#define DEV_SENSOR "/dev/v4l-subdev30"

#define WIDTH      4128
#define HEIGHT     3096
#define STRIDE     5168	/* camss pads the packed-10-bit stride to 16 bytes */
#define VALID      5160	/* 4128 pixels * 10 bits / 8 */
#define NUM_BUFS   4

#define FOCUS_MIN  0
#define FOCUS_MAX  1023

/* Frames thrown away after changing the lens or exposure, so the VCM ramp
 * and the sensor's exposure have settled before we measure. */
#define SETTLE_FRAMES 3
/* Frames averaged into one focus value, to beat sensor noise. */
#define MEASURE_FRAMES 2

struct buffer {
	void *start;
	size_t length;
};

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r == -1 && errno == EINTR);

	return r;
}

static int ctrl_set(int fd, uint32_t id, int32_t value)
{
	struct v4l2_control c = { .id = id, .value = value };

	return xioctl(fd, VIDIOC_S_CTRL, &c);
}

/*
 * Focus value: edge energy over an AF window.
 *
 * The frame is split into a grid of blocks and each block's mean squared
 * horizontal gradient is computed; the focus value is the mean of the best
 * quarter of them.  Averaging over the whole frame would drown the focus
 * signal in the noise floor of large featureless areas (a dark desk, a
 * wall), which is exactly the failure mode that makes contrast-detection AF
 * look like it does nothing.
 */
#define GW 8
#define GH 6
#define GW_TOP 12	/* GW * GH / 4 blocks contribute to the value */

static double block_fv(const uint8_t *data, int x0, int y0, int w, int h)
{
	double sum = 0;
	long n = 0;

	for (int y = y0; y < y0 + h; y += 4) {
		const uint8_t *row = data + (size_t)y * STRIDE;

		for (int x = x0; x + 1 < x0 + w; x++) {
			int d = (int)row[x + 1] - (int)row[x];

			sum += (double)d * d;
			n++;
		}
	}

	return n ? sum / n : 0;
}

static int cmp_desc(const void *a, const void *b)
{
	double da = *(const double *)a, db = *(const double *)b;

	return da < db ? 1 : da > db ? -1 : 0;
}

/* Reports how textured the scene is for AF: the ratio between the best and
 * worst window.  A scene with no depth contrast gives a flat curve, which is
 * indistinguishable from a stuck lens -- so say so instead of guessing. */
static double focus_value(const uint8_t *data)
{
	double blocks[GW * GH];
	double sum = 0;
	int bw = WIDTH / GW, bh = HEIGHT / GH;

	for (int gy = 0; gy < GH; gy++)
		for (int gx = 0; gx < GW; gx++)
			blocks[gy * GW + gx] =
				block_fv(data, gx * bw, gy * bh, bw, bh);

	qsort(blocks, GW * GH, sizeof(blocks[0]), cmp_desc);

	for (int i = 0; i < GW_TOP; i++)
		sum += blocks[i];

	return sum / GW_TOP;
}

/*
 * Mean of the unpacked 10-bit samples over a subsample of the frame, used by
 * the simple auto-exposure below.  MIPI RAW10: four pixels in five bytes,
 * with the two LSBs of each pixel packed into the fifth byte.
 */
static double mean_luma(const uint8_t *data)
{
	double sum = 0;
	long n = 0;

	for (int y = 0; y < HEIGHT; y += 24) {
		const uint8_t *row = data + (size_t)y * STRIDE;

		for (int g = 0; g < VALID / 5; g++) {
			const uint8_t *b = row + g * 5;

			sum += (double)(b[0] | ((b[4] & 0x03) << 8));
			sum += (double)(b[1] | ((b[4] & 0x0c) << 6));
			sum += (double)(b[2] | ((b[4] & 0x30) << 4));
			sum += (double)(b[3] | ((b[4] & 0xc0) << 2));
			n += 4;
		}
	}

	return n ? sum / n : 0;
}

struct camera {
	int fd;
	struct buffer buffers[NUM_BUFS];
	int lens_fd;
	int sensor_fd;
	int32_t exposure;
	int32_t gain;
};

static int camera_start(struct camera *cam)
{
	struct v4l2_format fmt = { 0 };
	struct v4l2_requestbuffers req = { 0 };
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

	cam->fd = open(DEV_VIDEO, O_RDWR);
	if (cam->fd < 0) {
		perror("open " DEV_VIDEO);
		return -1;
	}

	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	fmt.fmt.pix_mp.width = WIDTH;
	fmt.fmt.pix_mp.height = HEIGHT;
	fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_SGRBG10P;
	fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
	if (xioctl(cam->fd, VIDIOC_S_FMT, &fmt) < 0) {
		perror("VIDIOC_S_FMT");
		return -1;
	}

	req.count = NUM_BUFS;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(cam->fd, VIDIOC_REQBUFS, &req) < 0) {
		perror("VIDIOC_REQBUFS");
		return -1;
	}

	for (int i = 0; i < NUM_BUFS; i++) {
		struct v4l2_plane planes[VIDEO_MAX_PLANES] = { { 0 } };
		struct v4l2_buffer buf = { 0 };

		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		buf.m.planes = planes;
		buf.length = VIDEO_MAX_PLANES;
		if (xioctl(cam->fd, VIDIOC_QUERYBUF, &buf) < 0) {
			perror("VIDIOC_QUERYBUF");
			return -1;
		}

		cam->buffers[i].length = planes[0].length;
		cam->buffers[i].start = mmap(NULL, planes[0].length,
					     PROT_READ | PROT_WRITE,
					     MAP_SHARED, cam->fd,
					     planes[0].m.mem_offset);
		if (cam->buffers[i].start == MAP_FAILED) {
			perror("mmap");
			return -1;
		}

		if (xioctl(cam->fd, VIDIOC_QBUF, &buf) < 0) {
			perror("VIDIOC_QBUF");
			return -1;
		}
	}

	if (xioctl(cam->fd, VIDIOC_STREAMON, &type) < 0) {
		perror("VIDIOC_STREAMON");
		return -1;
	}

	return 0;
}

static void camera_stop(struct camera *cam)
{
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

	xioctl(cam->fd, VIDIOC_STREAMOFF, &type);
	for (int i = 0; i < NUM_BUFS; i++)
		munmap(cam->buffers[i].start, cam->buffers[i].length);
	close(cam->fd);
}

/* Grab one frame and hand its payload to the callback. */
static int camera_frame(struct camera *cam, double (*fn)(const uint8_t *),
			double *out)
{
	struct v4l2_plane planes[VIDEO_MAX_PLANES] = { { 0 } };
	struct v4l2_buffer buf = { 0 };
	int ret = 0;

	buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory = V4L2_MEMORY_MMAP;
	buf.m.planes = planes;
	buf.length = VIDEO_MAX_PLANES;
	if (xioctl(cam->fd, VIDIOC_DQBUF, &buf) < 0) {
		perror("VIDIOC_DQBUF");
		return -1;
	}

	if (fn)
		*out = fn(cam->buffers[buf.index].start);

	if (xioctl(cam->fd, VIDIOC_QBUF, &buf) < 0) {
		perror("VIDIOC_QBUF");
		ret = -1;
	}

	return ret;
}

static int discard(struct camera *cam, int n)
{
	for (int i = 0; i < n; i++)
		if (camera_frame(cam, NULL, NULL) < 0)
			return -1;
	return 0;
}

static double measure(struct camera *cam, double (*fn)(const uint8_t *))
{
	double acc = 0, v;

	if (discard(cam, SETTLE_FRAMES) < 0)
		return -1;

	for (int i = 0; i < MEASURE_FRAMES; i++) {
		if (camera_frame(cam, fn, &v) < 0)
			return -1;
		acc += v;
	}

	return acc / MEASURE_FRAMES;
}

/*
 * Very small auto-exposure: get the mean luma into a usable band so the focus
 * metric is not measuring a clipped or pitch-black frame.  Exposure is
 * preferred over analogue gain, to keep noise (and therefore the metric)
 * sane.
 */
static int auto_exposure(struct camera *cam)
{
	const double lo = 300.0, hi = 700.0;

	for (int i = 0; i < 10; i++) {
		double mean = measure(cam, mean_luma);
		int32_t next;

		if (mean < 0)
			return -1;

		if (mean >= lo && mean <= hi)
			return 0;

		if (mean < lo) {
			if (cam->exposure < 3260) {
				next = cam->exposure + cam->exposure / 4 + 16;
				if (next > 3260)
					next = 3260;
				cam->exposure = next;
			} else if (cam->gain < 240) {
				next = cam->gain + 24;
				cam->gain = next > 240 ? 240 : next;
			} else {
				return 0;	/* as bright as it gets */
			}
		} else {
			if (cam->exposure > 4) {
				next = cam->exposure - cam->exposure / 4;
				if (next < 4)
					next = 4;
				cam->exposure = next;
			} else if (cam->gain > 0) {
				next = cam->gain - 24;
				cam->gain = next < 0 ? 0 : next;
			} else {
				return 0;	/* as dark as it gets */
			}
		}

		ctrl_set(cam->sensor_fd, V4L2_CID_EXPOSURE, cam->exposure);
		ctrl_set(cam->sensor_fd, V4L2_CID_ANALOGUE_GAIN, cam->gain);
	}

	return 0;
}

static int set_focus(struct camera *cam, int pos)
{
	if (pos < FOCUS_MIN)
		pos = FOCUS_MIN;
	if (pos > FOCUS_MAX)
		pos = FOCUS_MAX;

	return ctrl_set(cam->lens_fd, V4L2_CID_FOCUS_ABSOLUTE, pos);
}

struct sample {
	int pos;
	double fv;
};

static struct sample probe(struct camera *cam, int pos)
{
	struct sample s = { .pos = pos, .fv = -1 };

	if (set_focus(cam, pos) < 0) {
		perror("focus_absolute");
		return s;
	}

	s.fv = measure(cam, focus_value);
	return s;
}

int main(int argc, char **argv)
{
	struct camera cam = { .fd = -1, .lens_fd = -1, .sensor_fd = -1,
			      .exposure = 3260, .gain = 64 };
	int only_pos = -1;
	int ret = EXIT_FAILURE;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-p") && i + 1 < argc)
			only_pos = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-g") && i + 1 < argc)
			cam.gain = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-e") && i + 1 < argc)
			cam.exposure = atoi(argv[++i]);
		else {
			fprintf(stderr, "usage: %s [-p position] [-g gain] "
				"[-e exposure]\n", argv[0]);
			return EXIT_FAILURE;
		}
	}

	cam.lens_fd = open(DEV_LENS, O_RDWR);
	if (cam.lens_fd < 0) {
		perror("open " DEV_LENS);
		return EXIT_FAILURE;
	}
	cam.sensor_fd = open(DEV_SENSOR, O_RDWR);
	if (cam.sensor_fd < 0) {
		perror("open " DEV_SENSOR);
		return EXIT_FAILURE;
	}

	if (only_pos >= 0) {
		if (set_focus(&cam, only_pos) < 0) {
			perror("set focus");
			return EXIT_FAILURE;
		}
		printf("focus set to %d\n", only_pos);
		return EXIT_SUCCESS;
	}

	ctrl_set(cam.sensor_fd, V4L2_CID_EXPOSURE, cam.exposure);
	ctrl_set(cam.sensor_fd, V4L2_CID_ANALOGUE_GAIN, cam.gain);

	if (camera_start(&cam) < 0)
		return EXIT_FAILURE;

	printf("auto-exposure...\n");
	if (auto_exposure(&cam) < 0)
		goto out;
	printf("  exposure %d, analogue gain %d\n", cam.exposure, cam.gain);

	/*
	 * Coarse sweep.  The lens range is 0..1023; nine points are enough to
	 * bracket the peak for a normal scene.
	 */
	struct sample best = { .pos = -1, .fv = -1 };
	double worst = 1e30;

	printf("coarse sweep:\n");
	for (int pos = FOCUS_MIN; pos <= FOCUS_MAX; pos += 128) {
		struct sample s = probe(&cam, pos);

		printf("  focus %4d  fv %10.1f\n", s.pos, s.fv);
		if (s.fv > best.fv)
			best = s;
		if (s.fv < worst)
			worst = s.fv;
	}

	/*
	 * If the curve barely moves the scene has no depth contrast to focus
	 * on (too flat, too dark, or everything beyond the lens range).  Say so
	 * rather than silently declaring a "best" position that is meaningless.
	 */
	if (best.fv / worst < 1.05) {
		printf("scene has too little depth contrast (curve spread %.1f%%) -- "
		       "aim at a close, well-lit, textured subject\n",
		       (best.fv / worst - 1) * 100);
		printf("best focus %d (fv %.1f) -- unreliable\n",
		       best.pos, best.fv);
		set_focus(&cam, best.pos);
		ret = EXIT_SUCCESS;
		goto out;
	}

	/*
	 * Fine pass: search the bracket around the coarse winner with a
	 * shrinking step, then hill-climb to the local maximum.
	 */
	int step = 128;

	while (step >= 4) {
		int lo = best.pos - step;
		int hi = best.pos + step;
		struct sample local = best;

		for (int pos = lo; pos <= hi; pos += step / 2) {
			struct sample s;

			if (pos < FOCUS_MIN || pos > FOCUS_MAX || pos == best.pos)
				continue;
			s = probe(&cam, pos);
			if (s.fv > local.fv)
				local = s;
		}

		if (local.fv > best.fv) {
			best = local;
			printf("  refine -> focus %4d  fv %10.1f (step %d)\n",
			       best.pos, best.fv, step);
		} else {
			step /= 2;
		}
	}

	printf("best focus %d (fv %.1f)\n", best.pos, best.fv);

	set_focus(&cam, best.pos);
	printf("lens left at %d\n", best.pos);

	ret = EXIT_SUCCESS;

out:
	camera_stop(&cam);
	return ret;
}
