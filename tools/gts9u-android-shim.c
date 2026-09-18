// SPDX-License-Identifier: GPL-2.0-only
/*
 * gts9wifi Android userspace shim (LD_PRELOAD).
 *
 * Samsung's Android SPSS daemons (sec_nvm, spdaemon) are bionic binaries that
 * expect a small part of Android's userland to exist:
 *
 *   1. libbinder's defaultServiceManager() loops until the Android property
 *      `servicemanager.ready` is "true" (libbinder contains the string "Waited
 *      for servicemanager.ready for a second, waiting another...").  The Ubuntu
 *      port has no Android property area (/dev/__properties__), so every
 *      property reads empty and libbase's WaitForProperty() burns 100% CPU
 *      forever - visible as a pure userspace spin with no syscalls, because
 *      the loop only reads memory and calls clock_gettime via the vDSO.
 *   2. liblog writes to logd's socket; with no logd present the diagnostics
 *      vanish, which is why the sibling Ultra port preloads its own
 *      liblog_capture.so.
 *
 * This shim interposes the bionic property and log entry points.  Properties
 * other than the overrides below keep behaving as "not found", so the daemons
 * otherwise see exactly the same (empty) environment as before.
 *
 * Freestanding: no libc, raw syscalls only, so the Android linker can load it
 * without glibc symbol-version resolution problems.
 *
 * Build (on the device, aarch64):
 *   gcc -shared -fPIC -nostdlib -O2 -ffreestanding -fno-builtin \
 *       -fno-tree-loop-distribute-patterns \
 *       -Wl,-soname,libgts9u-android-shim.so \
 *       -o libgts9u-android-shim.so gts9u-android-shim.c
 * and preload it with LD_PRELOAD=<runtime-root>/lib64/libgts9u-android-shim.so.
 *
 * Three groups of entry points are interposed:
 *   - bionic __system_property_*  (answer servicemanager.ready, else not-found)
 *   - liblog __android_log_*      (mirror to stderr, since there is no logd)
 *   - libhardware_legacy wakelocks and libvmmem VmMem  (see the notes below)
 */
#define NULL ((void *)0)

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long u64;
typedef long i64;

/* ---- raw syscalls (aarch64) ---- */
static i64 sys_call3(i64 n, i64 a, i64 b, i64 c)
{
	register i64 x0 __asm__("x0") = a;
	register i64 x1 __asm__("x1") = b;
	register i64 x2 __asm__("x2") = c;
	register i64 x8 __asm__("x8") = n;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static i64 sys_write(int fd, const void *buf, u64 len)
{
	return sys_call3(64 /* __NR_write */, fd, (i64)buf, (i64)len);
}

static void sys_exit(int code)
{
	register i64 x0 __asm__("x0") = code;
	register i64 x8 __asm__("x8") = 94 /* __NR_exit_group */;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
	for (;;)
		;
}

/* ---- minimal string helpers ---- */
static u64 slen(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	return n;
}

static int seq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (u8)*a - (u8)*b;
}

static void scopy(char *dst, const char *src)
{
	while (*src)
		*dst++ = *src++;
	*dst = '\0';
}

/* ---- property overrides ---- */
struct override {
	const char *name;
	const char *value;
};

static const struct override overrides[] = {
	{ "servicemanager.ready", "true" },
	{ NULL, NULL },
};

static const char *lookup(const char *name)
{
	int i;

	for (i = 0; overrides[i].name; i++)
		if (!seq(overrides[i].name, name))
			return overrides[i].value;
	return NULL;
}

/* bionic's prop_info is opaque; a stable non-NULL token is enough because
 * __system_property_read_callback() below never dereferences it.
 */
static u64 dummy_prop_info[8];

const void *__system_property_find(const char *name)
{
	return lookup(name) ? (const void *)dummy_prop_info : (const void *)0;
}

int __system_property_get(const char *name, char *value)
{
	const char *v = lookup(name);

	if (!v) {
		if (value)
			*value = '\0';
		return 0;
	}
	scopy(value, v);
	return (int)slen(v);
}

void __system_property_read_callback(const void *pi,
				     void (*callback)(void *cookie, const char *name,
						      const char *value, u32 serial),
				     void *cookie)
{
	(void)pi;
	if (callback)
		callback(cookie, "servicemanager.ready", "true", 1);
}

u32 __system_property_serial(const void *pi)
{
	(void)pi;
	return 1;
}

/* Report "changed" so a waiter re-reads instead of blocking forever. */
int __system_property_wait(const void *pi, u32 old_serial, u32 *new_serial,
			   const void *relative_timeout)
{
	(void)pi;
	(void)old_serial;
	(void)relative_timeout;
	if (new_serial)
		*new_serial = 1;
	return 1;
}

int __system_property_wait_any(u32 old_serial, u32 *new_serial, const void *relative_timeout)
{
	(void)old_serial;
	(void)relative_timeout;
	if (new_serial)
		*new_serial = 1;
	return 1;
}

const void *__system_property_find_nth(u32 n)
{
	(void)n;
	return (const void *)0;
}

void __system_property_foreach(void (*propfn)(const void *pi, void *cookie), void *cookie)
{
	(void)propfn;
	(void)cookie;
}

u32 __system_property_area_serial(void)
{
	return 1;
}

int __system_property_area_init(void)
{
	return 0;
}

/* ---- legacy wakelock API ----
 * spdaemon uses exactly two things from libhardware_legacy: acquire_wake_lock()
 * and release_wake_lock().  On this Android revision libhardware_legacy
 * implements those through the `android.system.suspend` AIDL HAL, so the calls
 * go libhardware_legacy -> android.system.suspend-V1-ndk -> libbinder ->
 * servicemanager.  There is no servicemanager on this port, so the daemon
 * blocks forever before it ever reaches SPCOM.  Take the calls directly instead:
 * use the kernel's PM wakelock node when it exists, otherwise just succeed (a
 * held wakelock only prevents suspend and is irrelevant to the SPU handshake).
 */
static int wake_open(const char *path)
{
	register i64 x0 __asm__("x0") = -100 /* AT_FDCWD */;
	register i64 x1 __asm__("x1") = (i64)path;
	register i64 x2 __asm__("x2") = 1 /* O_WRONLY */;
	register i64 x3 __asm__("x3") = 0;
	register i64 x8 __asm__("x8") = 56 /* __NR_openat */;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x8) : "memory");
	return (int)x0;
}

static void wake_log(const char *what, const char *id)
{
	char buf[96];
	u64 n = 0;
	const char *p;

	for (p = "[wakelock] "; *p && n < sizeof(buf) - 2; p++)
		buf[n++] = *p;
	for (p = what; *p && n < sizeof(buf) - 2; p++)
		buf[n++] = *p;
	buf[n++] = ' ';
	if (id)
		for (p = id; *p && n < sizeof(buf) - 2; p++)
			buf[n++] = *p;
	buf[n++] = '\n';
	sys_write(2, buf, n);
}

/* PARTIAL_WAKE_LOCK == 1 in <hardware_legacy/power.h>; ignore the class and
 * just mirror the name into the kernel node when one is present.
 */
int acquire_wake_lock(int lock, const char *id)
{
	int fd = wake_open("/sys/power/wake_lock");

	(void)lock;
	if (fd >= 0) {
		sys_write(fd, id, slen(id));
		sys_call3(57 /* __NR_close */, fd, 0, 0);
	} else {
		wake_log("acquire", id);
	}
	return 0;
}

int release_wake_lock(const char *id)
{
	int fd = wake_open("/sys/power/wake_unlock");

	if (fd >= 0) {
		sys_write(fd, id, slen(id));
		sys_call3(57 /* __NR_close */, fd, 0, 0);
	} else {
		wake_log("release", id);
	}
	return 0;
}

/* ---- liblog interception: mirror everything to stderr ---- */
#define LOG_BUF 1024

static char line[LOG_BUF];

static void emit(int prio, const char *tag, const char *text)
{
	u64 n = 0;
	const char *p;

	(void)prio;
	line[n++] = '[';
	if (tag)
		for (p = tag; *p && n < LOG_BUF - 6; p++)
			line[n++] = *p;
	line[n++] = ']';
	line[n++] = ' ';
	if (text)
		for (p = text; *p && n < LOG_BUF - 2; p++)
			line[n++] = *p;
	line[n++] = '\n';
	sys_write(2, line, n);
}

int __android_log_write(int prio, const char *tag, const char *text)
{
	emit(prio, tag, text);
	return 1;
}

int __android_log_buf_write(int bufid, int prio, const char *tag, const char *text)
{
	(void)bufid;
	return __android_log_write(prio, tag, text);
}

int __android_log_is_loggable(int prio, const char *tag, int default_prio)
{
	(void)prio;
	(void)tag;
	(void)default_prio;
	return 1;
}

int __android_log_is_loggable_len(int prio, const char *tag, unsigned long len, int default_prio)
{
	(void)prio;
	(void)tag;
	(void)len;
	(void)default_prio;
	return 1;
}

/* ---- tiny formatter for the variadic entry points ---- */
struct outbuf {
	char *p;
	char *end;
};

static void oput(struct outbuf *o, char c)
{
	if (o->p < o->end)
		*o->p++ = c;
}

static void oputs(struct outbuf *o, const char *s)
{
	if (!s)
		s = "(null)";
	while (*s)
		oput(o, *s++);
}

static void ounum(struct outbuf *o, u64 v, int base, int neg)
{
	char tmp[24];
	int i = 0;

	if (neg)
		oput(o, '-');
	if (!v)
		tmp[i++] = '0';
	while (v) {
		u64 d = v % (u64)base;

		tmp[i++] = (char)(d < 10 ? '0' + d : 'a' + (int)d - 10);
		v /= (u64)base;
	}
	while (i--)
		oput(o, tmp[i]);
}

static void vformat(char *dst, u64 dstlen, const char *fmt, __builtin_va_list ap)
{
	struct outbuf o = { dst, dst + dstlen - 1 };

	if (!fmt) {
		oputs(&o, "(null)");
	} else {
		while (*fmt) {
			if (*fmt != '%') {
				oput(&o, *fmt++);
				continue;
			}
			fmt++;
			if (*fmt == '%') {
				oput(&o, '%');
				fmt++;
				continue;
			}
			while (*fmt == '-' || *fmt == '+' || *fmt == ' ' || *fmt == '#' ||
			       *fmt == '0' || (*fmt >= '1' && *fmt <= '9') || *fmt == '.')
				fmt++;
			switch (*fmt) {
			case 's':
				oputs(&o, __builtin_va_arg(ap, const char *));
				break;
			case 'd':
			case 'i': {
				i64 v = __builtin_va_arg(ap, i64);

				if (v < 0)
					ounum(&o, (u64)(-v), 10, 1);
				else
					ounum(&o, (u64)v, 10, 0);
				break;
			}
			case 'u':
				ounum(&o, __builtin_va_arg(ap, u64), 10, 0);
				break;
			case 'x':
				ounum(&o, __builtin_va_arg(ap, u64), 16, 0);
				break;
			case 'p':
				oputs(&o, "0x");
				ounum(&o, __builtin_va_arg(ap, u64), 16, 0);
				break;
			case 'c':
				oput(&o, (char)__builtin_va_arg(ap, int));
				break;
			case '\0':
				break;
			default:
				oput(&o, '%');
				oput(&o, *fmt);
				break;
			}
			if (*fmt)
				fmt++;
		}
	}
	*o.p = '\0';
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	char msg[LOG_BUF];
	__builtin_va_list ap;

	__builtin_va_start(ap, fmt);
	vformat(msg, sizeof(msg), fmt, ap);
	__builtin_va_end(ap);
	emit(prio, tag, msg);
	return 1;
}

/* The SPSS daemons do all their logging through __android_log_buf_print(),
 * not __android_log_print(); without this they are completely silent because
 * liblog drops everything when logd is absent.
 */
int __android_log_buf_print(int bufid, int prio, const char *tag, const char *fmt, ...)
{
	char msg[LOG_BUF];
	__builtin_va_list ap;

	(void)bufid;
	__builtin_va_start(ap, fmt);
	vformat(msg, sizeof(msg), fmt, ap);
	__builtin_va_end(ap);
	emit(prio, tag, msg);
	return 1;
}

/* Legacy libcutils accessor; without an Android property area it returns the
 * caller's default, which is what we keep doing here.
 */
int property_get(const char *key, char *value, const char *default_value)
{
	const char *v = lookup(key);

	if (!v)
		v = default_value;
	if (!v) {
		if (value)
			*value = '\0';
		return 0;
	}
	scopy(value, v);
	return (int)slen(v);
}

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
	char msg[LOG_BUF];
	__builtin_va_list ap;

	__builtin_va_start(ap, fmt);
	vformat(msg, sizeof(msg), fmt, ap);
	__builtin_va_end(ap);
	emit(7, tag, msg);
	emit(7, tag, cond);
	sys_exit(134);
}

/* ---- libvmmem (Samsung VmMem / mem_buf) interception --------------------
 *
 * libspcom's spcom_ion_alloc_ex() allocates the SPSS NVM buffer from the
 * "qcom,sp-hlos" DMA-BUF heap and then hands the fd to libvmmem so that the
 * hypervisor grants CP_SPSS_HLOS_SHARED access to it ("hyp_assign").  libvmmem
 * implements that with Samsung's downstream mem_buf driver, which mainline
 * does not have, so VmMem::CreateVmMem() fails (it cannot find /dev/membuf)
 * and libspcom aborts the whole NVM request - which is what makes the SPU
 * watchdog-bite a fraction of a second after it boots.
 *
 * On this port the same ownership transition is performed *inside* the DMA-BUF
 * heap: qcom_sp_hlos_heap.c calls qcom_scm_assign_mem() with
 * QCOM_SCM_VMID_CP_SPSS_HLOS_SHARED when the buffer is allocated and revokes it
 * when it is freed, so the grant has exactly the DMA-BUF's lifetime.  By the
 * time userspace asks for the grant it has therefore already been made, and
 * the mem_buf round trip is redundant.  Answer these calls the way a
 * successful mem_buf ioctl would, and log each one so it stays visible.
 */
static void vm_log(const char *msg, const char *name, long val, int has_val)
{
	char b[160];
	struct outbuf o = { b, b + sizeof(b) - 1 };

	oputs(&o, msg);
	if (name) {
		oput(&o, ' ');
		oputs(&o, name);
	}
	if (has_val) {
		oput(&o, ' ');
		ounum(&o, (u64)(val < 0 ? -val : val), 10, val < 0);
	}
	*o.p = '\0';
	emit(4, "vmmem", b);
}

/* Best-effort, crash-free view of a libc++ std::string: only the short form is
 * read in place, the long form is reported by pointer.
 */
static const char *vm_str(const void *p)
{
	const u8 *b = (const u8 *)p;

	if (!p)
		return "(null)";
	if (b[0] & 1)
		return "(long)";
	return (const char *)(b + 1);
}

void *CreateVmMem(void)
{
	vm_log("CreateVmMem -> stub handle (heap already owns the transition)", NULL, -1, 0);
	return (void *)1;
}

int FreeVmMem(void *vmem)
{
	(void)vmem;
	vm_log("FreeVmMem", NULL, -1, 0);
	return 0;
}

int FindVmByName(void *vmem, const void *name)
{
	(void)vmem;
	vm_log("FindVmByName", vm_str(name), -1, 0);
	return 1;
}

int ShareDmabuf(void *vmem, int fd, const void *acl, long *out)
{
	(void)vmem;
	(void)acl;
	if (out)
		*out = 0;
	vm_log("ShareDmabuf (already granted by qcom,sp-hlos)", NULL, fd, 1);
	return 0;
}

int LendDmabuf(void *vmem, int fd, const void *acl, long *out)
{
	(void)vmem;
	(void)acl;
	if (out)
		*out = 0;
	vm_log("LendDmabuf", NULL, fd, 1);
	return 0;
}

int RetrieveDmabuf(void *vmem, int fd, const void *acl, long out)
{
	(void)vmem;
	(void)acl;
	(void)out;
	vm_log("RetrieveDmabuf", NULL, fd, 1);
	return 0;
}

int ReclaimDmabuf(void *vmem, int fd, long out)
{
	(void)vmem;
	(void)out;
	vm_log("ReclaimDmabuf", NULL, fd, 1);
	return 0;
}
