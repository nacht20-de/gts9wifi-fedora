// SPDX-License-Identifier: GPL-2.0
/*
 * STMicroelectronics FTS1BA90A touchscreen driver.
 *
 * The register protocol comes from Samsung's GPL-2.0 downstream sec_ts/fts
 * driver for the Galaxy Tab S9 (SM-X710). Only coordinate reporting is
 * implemented; the controller runs its factory-flashed firmware.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>
#include <linux/unaligned.h>

#define FTS_READ_DEVICE_ID		0x22
#define FTS_READ_FW_VERSION		0x24
#define FTS_SET_TOUCH_FUNCTION		0x30
#define FTS_READ_ONE_EVENT		0x60
#define FTS_READ_ALL_EVENT		0x61
#define FTS_CLEAR_ALL_EVENT		0x62
#define FTS_SET_SCAN_MODE		0xa0

#define FTS_CHIP_ID0			0x39
#define FTS_CHIP_ID1			0x36

/* FTS_SET_TOUCH_FUNCTION bits */
#define FTS_TOUCHTYPE_TOUCH		BIT(0)
#define FTS_TOUCHTYPE_PALM		BIT(5)
#define FTS_TOUCHTYPE_WET		BIT(6)

#define FTS_SCAN_MODE_OFF		0x00
#define FTS_SCAN_MODE_MS_SS		0x01

#define FTS_EVENT_SIZE			16
#define FTS_FIFO_MAX			32

/* event id in byte 0 bits [1:0] */
#define FTS_EV_COORDINATE		0
#define FTS_EV_STATUS			1

#define FTS_EV_ERROR_REPORT		0xf3

/* status event: stype in byte 0 bits [5:2], id in byte 1 */
#define FTS_STATUS_TYPE_INFO		2
#define FTS_INFO_READY			0x00

/* coordinate event: action in byte 0 bits [7:6] */
#define FTS_ACTION_PRESS		1
#define FTS_ACTION_MOVE			2
#define FTS_ACTION_RELEASE		3

/* touch type from byte 6 bits [7:6] and byte 7 bits [7:6] */
#define FTS_TTYPE_NORMAL		0
#define FTS_TTYPE_GLOVE			3
#define FTS_TTYPE_PALM			5
#define FTS_TTYPE_WET			6

#define FTS_MAX_FINGERS			10
#define FTS_MAX_X			1599
#define FTS_MAX_Y			2559
#define FTS_MAX_PRESSURE		63

struct fts1ba90a {
	struct i2c_client *client;
	struct input_dev *input;
	struct touchscreen_properties prop;
	struct regulator *avdd;
	struct regulator *vddio;
	u8 events[FTS_FIFO_MAX * FTS_EVENT_SIZE];
};

static int fts1ba90a_write(struct fts1ba90a *ts, const u8 *cmd, int len)
{
	int ret;

	ret = i2c_master_send(ts->client, cmd, len);
	if (ret < 0)
		return ret;
	if (ret != len)
		return -EIO;

	return 0;
}

static int fts1ba90a_read(struct fts1ba90a *ts, const u8 *cmd, int cmdlen,
			  u8 *buf, int len)
{
	struct i2c_msg msgs[] = {
		{
			.addr = ts->client->addr,
			.len = cmdlen,
			.buf = (u8 *)cmd,
		}, {
			.addr = ts->client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = buf,
		},
	};
	int ret;

	ret = i2c_transfer(ts->client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret < 0)
		return ret;
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	return 0;
}

/*
 * After reset the firmware queues an information/ready status event.
 * Poll the event FIFO until it shows up; the downstream driver allows
 * about three seconds.
 */
static int fts1ba90a_wait_for_ready(struct fts1ba90a *ts)
{
	u8 cmd = FTS_READ_ONE_EVENT;
	u8 ev[FTS_EVENT_SIZE];
	int retry, ret;

	for (retry = 0; retry < 100; retry++) {
		ret = fts1ba90a_read(ts, &cmd, 1, ev, sizeof(ev));
		if (ret)
			return ret;

		if ((ev[0] & 0x3) == FTS_EV_STATUS &&
		    ((ev[0] >> 2) & 0xf) == FTS_STATUS_TYPE_INFO &&
		    ev[1] == FTS_INFO_READY)
			return 0;

		if (ev[0] == FTS_EV_ERROR_REPORT)
			dev_err(&ts->client->dev, "error event: %*ph\n", 8, ev);

		msleep(20);
	}

	return -ETIMEDOUT;
}

static int fts1ba90a_reset(struct fts1ba90a *ts)
{
	static const u8 sysreset[] = { 0xfa, 0x20, 0x00, 0x00, 0x24, 0x81 };
	int ret;

	ret = fts1ba90a_write(ts, sysreset, sizeof(sysreset));
	if (ret)
		return ret;

	usleep_range(10000, 11000);

	return fts1ba90a_wait_for_ready(ts);
}

static int fts1ba90a_sense_on(struct fts1ba90a *ts)
{
	u8 cmd[3];
	int ret;

	cmd[0] = FTS_SET_TOUCH_FUNCTION;
	cmd[1] = FTS_TOUCHTYPE_TOUCH | FTS_TOUCHTYPE_PALM | FTS_TOUCHTYPE_WET;
	cmd[2] = 0;
	ret = fts1ba90a_write(ts, cmd, 3);
	if (ret)
		return ret;

	cmd[0] = FTS_CLEAR_ALL_EVENT;
	ret = fts1ba90a_write(ts, cmd, 1);
	if (ret)
		return ret;

	cmd[0] = FTS_SET_SCAN_MODE;
	cmd[1] = 0x00;
	cmd[2] = FTS_SCAN_MODE_MS_SS;
	ret = fts1ba90a_write(ts, cmd, 3);
	if (ret)
		return ret;

	msleep(50);

	return 0;
}

static int fts1ba90a_start(struct fts1ba90a *ts)
{
	int ret;

	ret = fts1ba90a_reset(ts);
	if (ret)
		return ret;

	return fts1ba90a_sense_on(ts);
}

static int fts1ba90a_power_on(struct fts1ba90a *ts)
{
	int ret;

	ret = regulator_enable(ts->vddio);
	if (ret)
		return ret;

	/* downstream raises the IO rail 1 ms ahead of the analog rail */
	usleep_range(1000, 2000);

	ret = regulator_enable(ts->avdd);
	if (ret) {
		regulator_disable(ts->vddio);
		return ret;
	}

	usleep_range(10000, 11000);

	return 0;
}

static void fts1ba90a_power_off(void *data)
{
	struct fts1ba90a *ts = data;

	regulator_disable(ts->avdd);
	usleep_range(4000, 5000);
	regulator_disable(ts->vddio);
}

static void fts1ba90a_report_event(struct fts1ba90a *ts, const u8 *ev)
{
	unsigned int slot, action, ttype, x, y, z;

	if ((ev[0] & 0x3) != FTS_EV_COORDINATE)
		return;

	slot = (ev[0] >> 2) & 0xf;
	if (slot >= FTS_MAX_FINGERS)
		return;

	ttype = ((ev[6] >> 6) << 2) | (ev[7] >> 6);
	switch (ttype) {
	case FTS_TTYPE_NORMAL:
	case FTS_TTYPE_GLOVE:
	case FTS_TTYPE_PALM:
	case FTS_TTYPE_WET:
		break;
	default:
		return;
	}

	input_mt_slot(ts->input, slot);

	action = ev[0] >> 6;
	if (action == FTS_ACTION_RELEASE) {
		input_mt_report_slot_inactive(ts->input);
		return;
	}

	if (action != FTS_ACTION_PRESS && action != FTS_ACTION_MOVE)
		return;

	x = (ev[1] << 4) | (ev[3] >> 4);
	y = (ev[2] << 4) | (ev[3] & 0xf);
	z = ev[6] & 0x3f;

	input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
	touchscreen_report_pos(ts->input, &ts->prop, x, y, true);
	input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, ev[4]);
	input_report_abs(ts->input, ABS_MT_TOUCH_MINOR, ev[5]);
	input_report_abs(ts->input, ABS_MT_PRESSURE, z ? z : 1);
}

static irqreturn_t fts1ba90a_irq_handler(int irq, void *dev_id)
{
	struct fts1ba90a *ts = dev_id;
	u8 cmd = FTS_READ_ONE_EVENT;
	int count, i, ret;

	ret = fts1ba90a_read(ts, &cmd, 1, ts->events, FTS_EVENT_SIZE);
	if (ret)
		return IRQ_HANDLED;

	/* remaining FIFO depth rides in byte 7 of every event */
	count = (ts->events[7] & 0x3f) + 1;
	if (count > FTS_FIFO_MAX)
		count = FTS_FIFO_MAX;

	if (count > 1) {
		cmd = FTS_READ_ALL_EVENT;
		ret = fts1ba90a_read(ts, &cmd, 1,
				     ts->events + FTS_EVENT_SIZE,
				     (count - 1) * FTS_EVENT_SIZE);
		if (ret)
			count = 1;
	}

	for (i = 0; i < count; i++)
		fts1ba90a_report_event(ts, ts->events + i * FTS_EVENT_SIZE);

	input_mt_sync_frame(ts->input);
	input_sync(ts->input);

	return IRQ_HANDLED;
}

static void fts1ba90a_report_version(struct fts1ba90a *ts)
{
	u8 cmd = FTS_READ_DEVICE_ID;
	u8 id[5];
	u8 fw[9];
	int ret;

	ret = fts1ba90a_read(ts, &cmd, 1, id, sizeof(id));
	if (ret)
		return;

	if (id[2] != FTS_CHIP_ID0 || id[3] != FTS_CHIP_ID1)
		dev_warn(&ts->client->dev, "unexpected chip id: %*ph\n",
			 (int)sizeof(id), id);

	cmd = FTS_READ_FW_VERSION;
	ret = fts1ba90a_read(ts, &cmd, 1, fw, sizeof(fw));
	if (ret)
		return;

	dev_info(&ts->client->dev,
		 "fw version 0x%04x, config 0x%04x, main 0x%04x\n",
		 get_unaligned_be16(&fw[0]), get_unaligned_be16(&fw[2]),
		 get_unaligned_le16(&fw[4]));
}

static int fts1ba90a_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct fts1ba90a *ts;
	struct input_dev *input;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENODEV;

	if (!client->irq)
		return dev_err_probe(dev, -EINVAL, "no irq specified\n");

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->client = client;
	i2c_set_clientdata(client, ts);

	ts->avdd = devm_regulator_get(dev, "avdd");
	if (IS_ERR(ts->avdd))
		return dev_err_probe(dev, PTR_ERR(ts->avdd),
				     "failed to get avdd\n");

	ts->vddio = devm_regulator_get(dev, "vddio");
	if (IS_ERR(ts->vddio))
		return dev_err_probe(dev, PTR_ERR(ts->vddio),
				     "failed to get vddio\n");

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;

	ts->input = input;
	input->name = "FTS1BA90A Touchscreen";
	input->id.bustype = BUS_I2C;

	input_set_abs_params(input, ABS_MT_POSITION_X, 0, FTS_MAX_X, 0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, FTS_MAX_Y, 0, 0);
	input_set_abs_params(input, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	input_set_abs_params(input, ABS_MT_TOUCH_MINOR, 0, 255, 0, 0);
	input_set_abs_params(input, ABS_MT_PRESSURE, 0, FTS_MAX_PRESSURE, 0, 0);

	touchscreen_parse_properties(input, true, &ts->prop);

	ret = input_mt_init_slots(input, FTS_MAX_FINGERS,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;

	ret = fts1ba90a_power_on(ts);
	if (ret)
		return dev_err_probe(dev, ret, "failed to power on\n");

	ret = devm_add_action_or_reset(dev, fts1ba90a_power_off, ts);
	if (ret)
		return ret;

	ret = fts1ba90a_start(ts);
	if (ret)
		return dev_err_probe(dev, ret, "failed to initialize\n");

	fts1ba90a_report_version(ts);

	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					fts1ba90a_irq_handler, IRQF_ONESHOT,
					client->name, ts);
	if (ret)
		return dev_err_probe(dev, ret, "failed to request irq\n");

	ret = input_register_device(input);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register input\n");

	return 0;
}

static int fts1ba90a_suspend(struct device *dev)
{
	struct fts1ba90a *ts = dev_get_drvdata(dev);

	disable_irq(ts->client->irq);
	fts1ba90a_power_off(ts);

	return 0;
}

static int fts1ba90a_resume(struct device *dev)
{
	struct fts1ba90a *ts = dev_get_drvdata(dev);
	int ret;

	ret = fts1ba90a_power_on(ts);
	if (ret)
		return ret;

	ret = fts1ba90a_start(ts);
	if (ret)
		return ret;

	enable_irq(ts->client->irq);

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(fts1ba90a_pm_ops,
				fts1ba90a_suspend, fts1ba90a_resume);

static const struct of_device_id fts1ba90a_of_match[] = {
	{ .compatible = "st,fts1ba90a" },
	{ }
};
MODULE_DEVICE_TABLE(of, fts1ba90a_of_match);

static const struct i2c_device_id fts1ba90a_id[] = {
	{ "fts1ba90a" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, fts1ba90a_id);

static struct i2c_driver fts1ba90a_driver = {
	.driver = {
		.name = "fts1ba90a",
		.of_match_table = fts1ba90a_of_match,
		.pm = pm_sleep_ptr(&fts1ba90a_pm_ops),
		.probe_type = PROBE_PREFER_ASYNCHRONOUS,
	},
	.probe = fts1ba90a_probe,
	.id_table = fts1ba90a_id,
};
module_i2c_driver(fts1ba90a_driver);

MODULE_DESCRIPTION("STMicroelectronics FTS1BA90A touchscreen driver");
MODULE_LICENSE("GPL");
