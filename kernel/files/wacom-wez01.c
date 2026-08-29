// SPDX-License-Identifier: GPL-2.0
/*
 * Wacom WEZ01 EMR digitizer (S Pen) driver.
 *
 * The raw sec-wacom protocol comes from Samsung's GPL-2.0 downstream wacom
 * driver for the Galaxy Tab S9 (SM-X710), cross-checked against the Tab S8+
 * mainline port. Only pen reporting is implemented; the IC runs its
 * factory-flashed firmware, so no firmware download path is needed.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>
#include <linux/unaligned.h>

#define WEZ01_COM_SURVEY_EXIT		0x2d
#define WEZ01_COM_SAMPLERATE_STOP	0x30
#define WEZ01_COM_SAMPLERATE_START	0x31

/*
 * There is no query command at runtime: a raw 32-byte read returns the last
 * coordinate frame followed by the 16-byte query block, tagged by its header.
 */
#define WEZ01_QUERY_SIZE		32
#define WEZ01_QUERY_POS			16
#define WEZ01_QUERY_HEADER		0x0f

/* query block offsets */
#define WEZ01_QRY_X			1
#define WEZ01_QRY_Y			3
#define WEZ01_QRY_PRESSURE		5
#define WEZ01_QRY_FWVER			7
#define WEZ01_QRY_MPUVER		9
#define WEZ01_QRY_TILT_X		11
#define WEZ01_QRY_TILT_Y		12
#define WEZ01_QRY_HEIGHT		13

#define WEZ01_MPU_ID			0x46

/* event packets are 16 bytes, read with one ack byte appended */
#define WEZ01_EVENT_SIZE		16

/* packet id in byte 0 bits [3:0] */
#define WEZ01_PKT_COORD			1

/* coordinate packet byte 0 flags */
#define WEZ01_RDY			BIT(7)
#define WEZ01_ERASER			BIT(6)
#define WEZ01_SIDE			BIT(5)
#define WEZ01_TIP			BIT(4)

/* 100 units/mm across the 11" panel's active area; libinput requires it */
#define WEZ01_RES_UNITS_PER_MM		100

struct wacom_wez01 {
	struct i2c_client *client;
	struct input_dev *input;
	struct touchscreen_properties prop;
	struct gpio_desc *fwe;
	u16 max_x;
	u16 max_y;
	u16 max_pressure;
	u8 max_height;
	s8 max_tilt_x;
	s8 max_tilt_y;
	bool prox;
};

static int wacom_wez01_send(struct wacom_wez01 *w, u8 cmd)
{
	int ret;

	ret = i2c_master_send(w->client, &cmd, 1);
	if (ret < 0)
		return ret;
	if (ret != 1)
		return -EIO;

	return 0;
}

static int wacom_wez01_query(struct wacom_wez01 *w)
{
	u8 buf[WEZ01_QUERY_SIZE];
	const u8 *q = buf + WEZ01_QUERY_POS;
	int retry, ret;

	for (retry = 0; retry < 10; retry++) {
		ret = i2c_master_recv(w->client, buf, sizeof(buf));
		if (ret == sizeof(buf) && q[0] == WEZ01_QUERY_HEADER)
			break;

		msleep(20);
	}

	if (retry == 10)
		return ret < 0 ? ret : -EIO;

	w->max_x = get_unaligned_be16(&q[WEZ01_QRY_X]);
	w->max_y = get_unaligned_be16(&q[WEZ01_QRY_Y]);
	w->max_pressure = get_unaligned_be16(&q[WEZ01_QRY_PRESSURE]);
	w->max_tilt_x = q[WEZ01_QRY_TILT_X];
	w->max_tilt_y = q[WEZ01_QRY_TILT_Y];
	w->max_height = q[WEZ01_QRY_HEIGHT];

	if (q[WEZ01_QRY_MPUVER] != WEZ01_MPU_ID)
		dev_warn(&w->client->dev, "unexpected mpu id 0x%02x\n",
			 q[WEZ01_QRY_MPUVER]);

	dev_info(&w->client->dev,
		 "fw version 0x%04x, max_x %u, max_y %u, max_pressure %u\n",
		 get_unaligned_be16(&q[WEZ01_QRY_FWVER]),
		 w->max_x, w->max_y, w->max_pressure);

	return 0;
}

static void wacom_wez01_release(struct wacom_wez01 *w)
{
	if (!w->prox)
		return;

	input_report_abs(w->input, ABS_PRESSURE, 0);
	input_report_abs(w->input, ABS_DISTANCE, 0);
	input_report_key(w->input, BTN_TOUCH, 0);
	input_report_key(w->input, BTN_STYLUS, 0);
	input_report_key(w->input, BTN_TOOL_PEN, 0);
	input_report_key(w->input, BTN_TOOL_RUBBER, 0);
	input_sync(w->input);
	w->prox = false;
}

static irqreturn_t wacom_wez01_irq_handler(int irq, void *dev_id)
{
	struct wacom_wez01 *w = dev_id;
	u8 data[WEZ01_EVENT_SIZE + 1];
	int ret;

	ret = i2c_master_recv(w->client, data, sizeof(data));
	if (ret != sizeof(data))
		return IRQ_HANDLED;

	if ((data[0] & 0x0f) != WEZ01_PKT_COORD)
		return IRQ_HANDLED;

	if (!(data[0] & WEZ01_RDY)) {
		wacom_wez01_release(w);
		return IRQ_HANDLED;
	}

	input_report_key(w->input, BTN_TOOL_RUBBER, !!(data[0] & WEZ01_ERASER));
	input_report_key(w->input, BTN_TOOL_PEN, !(data[0] & WEZ01_ERASER));
	input_report_key(w->input, BTN_TOUCH, !!(data[0] & WEZ01_TIP));
	input_report_key(w->input, BTN_STYLUS, !!(data[0] & WEZ01_SIDE));
	touchscreen_report_pos(w->input, &w->prop,
			       get_unaligned_be16(&data[1]),
			       get_unaligned_be16(&data[3]), false);
	input_report_abs(w->input, ABS_PRESSURE,
			 ((data[5] & 0x0f) << 8) | data[6]);
	input_report_abs(w->input, ABS_DISTANCE, data[7]);
	input_report_abs(w->input, ABS_TILT_X, (s8)data[8]);
	input_report_abs(w->input, ABS_TILT_Y, (s8)data[9]);
	input_sync(w->input);
	w->prox = true;

	return IRQ_HANDLED;
}

static int wacom_wez01_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct wacom_wez01 *w;
	struct input_dev *input;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
		return -ENODEV;

	if (!client->irq)
		return dev_err_probe(dev, -EINVAL, "no irq specified\n");

	w = devm_kzalloc(dev, sizeof(*w), GFP_KERNEL);
	if (!w)
		return -ENOMEM;

	w->client = client;
	i2c_set_clientdata(client, w);

	/*
	 * avdd is shared with the panel VCI rail; the enable is refcounted
	 * and the driver never power-cycles the pen.
	 */
	ret = devm_regulator_get_enable(dev, "avdd");
	if (ret)
		return dev_err_probe(dev, ret, "failed to enable avdd\n");

	/* high (plus a power cycle) selects the flash-mode bootloader */
	w->fwe = devm_gpiod_get(dev, "flash-mode", GPIOD_OUT_LOW);
	if (IS_ERR(w->fwe))
		return dev_err_probe(dev, PTR_ERR(w->fwe),
				     "failed to get flash-mode gpio\n");

	msleep(200);

	ret = wacom_wez01_query(w);
	if (ret) {
		dev_warn(dev, "query failed (%d), using default limits\n", ret);
		w->max_x = 14752;
		w->max_y = 23603;
		w->max_pressure = 4095;
		w->max_height = 255;
		w->max_tilt_x = 63;
		w->max_tilt_y = 63;
	}

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;

	w->input = input;
	input->name = "Wacom WEZ01 S Pen";
	input->id.bustype = BUS_I2C;

	input_set_capability(input, EV_KEY, BTN_TOUCH);
	input_set_capability(input, EV_KEY, BTN_STYLUS);
	input_set_capability(input, EV_KEY, BTN_TOOL_PEN);
	input_set_capability(input, EV_KEY, BTN_TOOL_RUBBER);

	input_set_abs_params(input, ABS_X, 0, w->max_x, 4, 0);
	input_set_abs_params(input, ABS_Y, 0, w->max_y, 4, 0);
	input_set_abs_params(input, ABS_PRESSURE, 0, w->max_pressure, 0, 0);
	input_set_abs_params(input, ABS_DISTANCE, 0, w->max_height, 0, 0);
	input_set_abs_params(input, ABS_TILT_X, -w->max_tilt_x, w->max_tilt_x,
			     0, 0);
	input_set_abs_params(input, ABS_TILT_Y, -w->max_tilt_y, w->max_tilt_y,
			     0, 0);
	input_abs_set_res(input, ABS_X, WEZ01_RES_UNITS_PER_MM);
	input_abs_set_res(input, ABS_Y, WEZ01_RES_UNITS_PER_MM);

	__set_bit(INPUT_PROP_DIRECT, input->propbit);

	touchscreen_parse_properties(input, false, &w->prop);

	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					wacom_wez01_irq_handler, IRQF_ONESHOT,
					client->name, w);
	if (ret)
		return dev_err_probe(dev, ret, "failed to request irq\n");

	ret = input_register_device(input);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register input\n");

	wacom_wez01_send(w, WEZ01_COM_SAMPLERATE_START);

	return 0;
}

static int wacom_wez01_suspend(struct device *dev)
{
	struct wacom_wez01 *w = dev_get_drvdata(dev);

	disable_irq(w->client->irq);
	wacom_wez01_send(w, WEZ01_COM_SAMPLERATE_STOP);

	return 0;
}

static int wacom_wez01_resume(struct device *dev)
{
	struct wacom_wez01 *w = dev_get_drvdata(dev);

	wacom_wez01_send(w, WEZ01_COM_SURVEY_EXIT);
	wacom_wez01_send(w, WEZ01_COM_SAMPLERATE_START);
	enable_irq(w->client->irq);

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(wacom_wez01_pm_ops,
				wacom_wez01_suspend, wacom_wez01_resume);

static const struct of_device_id wacom_wez01_of_match[] = {
	{ .compatible = "wacom,w90xx" },
	{ }
};
MODULE_DEVICE_TABLE(of, wacom_wez01_of_match);

static const struct i2c_device_id wacom_wez01_id[] = {
	{ "wacom-wez01" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, wacom_wez01_id);

static struct i2c_driver wacom_wez01_driver = {
	.driver = {
		.name = "wacom-wez01",
		.of_match_table = wacom_wez01_of_match,
		.pm = pm_sleep_ptr(&wacom_wez01_pm_ops),
		.probe_type = PROBE_PREFER_ASYNCHRONOUS,
	},
	.probe = wacom_wez01_probe,
	.id_table = wacom_wez01_id,
};
module_i2c_driver(wacom_wez01_driver);

MODULE_DESCRIPTION("Wacom WEZ01 EMR digitizer driver");
MODULE_LICENSE("GPL");
