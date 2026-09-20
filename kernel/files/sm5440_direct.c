// SPDX-License-Identifier: GPL-2.0-only
/*
 * Silicon Mitus SM5440 2:1 direct charger for the Samsung SM-X710.
 *
 * This is a deliberately small mainline-first driver.  Linux TCPM owns USB-PD
 * policy; this driver only requests a conservative PPS operating point, hands
 * the battery path over from SM5714, and programs the board's charge pump using
 * the register sequence published in Samsung's GPL source.  Every failure
 * turns the pump off and restores the fixed-PD switching charger.
 *
 * Direct charging is off by default -- see the direct_charge parameter below.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/power_supply.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

/*
 * Interrupt latches.  They are read-to-clear, and they are the only thing that
 * says *why* the chip cut the pump off -- otherwise a stop is just "CHG_ON went
 * away".  Bit names follow Silicon Mitus' own driver header.
 */
#define SM5440_REG_INT1			0x00
#define SM5440_REG_INT3			0x02
#define  SM5440_INT1_VOUTOVP		BIT(4)
#define  SM5440_INT1_VBATOVP		BIT(3)
#define  SM5440_INT3_VBUSOVP		BIT(7)
#define  SM5440_INT3_VBUSUVLO		BIT(6)
#define  SM5440_INT3_THEMSHDN		BIT(3)
#define  SM5440_INT3_STUP_FAIL		BIT(2)
#define  SM5440_INT3_REVBLK		BIT(1)
#define  SM5440_INT3_CFLY_SHORT		BIT(0)
#define SM5440_REG_STATUS1		0x08
#define SM5440_REG_STATUS3		0x0a
#define  SM5440_STATUS3_VBUSPOK		BIT(5)
#define SM5440_REG_CNTL1		0x0c
#define  SM5440_CNTL1_SW_RESET		BIT(0)
#define  SM5440_CNTL1_WDT_EN		BIT(7)
#define  SM5440_CNTL1_WDT_30S		(4 << 4)
#define SM5440_REG_CNTL2		0x0d
#define SM5440_REG_CNTL3		0x0e
#define SM5440_REG_CNTL4		0x0f
#define SM5440_REG_CNTL5		0x10
#define  SM5440_CNTL5_OP_MODE_MASK	GENMASK(3, 2)
#define  SM5440_CNTL5_CHG_ON		BIT(2)
#define SM5440_REG_CNTL6		0x11
#define SM5440_REG_CNTL7		0x12
#define SM5440_REG_VBUSCNTL		0x13
#define SM5440_REG_VBATCNTL		0x14
#define SM5440_REG_VOUTCNTL		0x15
#define SM5440_REG_IBUSCNTL		0x16
#define SM5440_REG_PRTNCNTL		0x19
#define SM5440_REG_THEMCNTL1		0x1a
#define SM5440_REG_ADCCNTL1		0x1c
#define  SM5440_ADCCNTL1_AVG_32		BIT(3)
#define  SM5440_ADCCNTL1_CONTINUOUS	BIT(1)
#define  SM5440_ADCCNTL1_ENABLE	BIT(0)
#define SM5440_REG_ADCCNTL2		0x1d
#define SM5440_REG_ADC_VBUS1		0x1e
#define SM5440_REG_ADC_IBUS1		0x22
#define SM5440_REG_ADC_DIETEMP		0x26
#define SM5440_REG_ADC_VBAT1		0x27
#define SM5440_REG_DEVICEID		0x2b

#define SM5440_POLL_MS			1000
#define SM5440_RETRY_MS			2000
#define SM5440_MAX_RETRY_MS		30000
#define SM5440_QUIET_RETRY_MS		300000
#define SM5440_MAX_FAILS		5

/*
 * TCPM answers -EAGAIN while its state machine is not in SNK_READY, or while the
 * source has not signalled SinkTxOK yet.  That is a "try again" condition, not
 * a failure, so the PD properties are retried briefly before giving up.
 */
#define SM5440_PD_RETRY_MS		200
#define SM5440_PD_RETRIES		5

#define SM5440_INITIAL_IBUS_MA		1800
#define SM5440_VBATREG_MV		4400

/*
 * How much input current to ask the adapter for.
 *
 * The board's own budget is 3 A at 9 V (Samsung's board data), which is also what
 * a standard USB-C cable is rated for, so that is the default.  An e-marked 5 A
 * cable and an adapter that grants it can go higher; whatever the source refuses
 * is discovered at run time by walking down from this value.
 */
#define SM5440_MAX_PPS_MA		3000
#define SM5440_PPS_CAP_MA		5000
#define SM5440_MIN_PPS_MA		1800
#define SM5440_PPS_STEP_MA		250
#define SM5440_IBUS_MARGIN_MA		300
#define SM5440_PPS_V_STEP_MV		20
#define SM5440_REFRESH_TICKS		4

static unsigned int max_pps_ma = SM5440_MAX_PPS_MA;
module_param(max_pps_ma, uint, 0644);
MODULE_PARM_DESC(max_pps_ma,
		 "Highest PPS input current to request, in mA (default 3000, max 5000)");

/*
 * Board tuning from the X710 device tree (sm5440,freq = 850, freq_siop = 450
 * 650, r_ttl = 320000): the vendor driver drops the pump's switching frequency
 * at low charge current and keeps the drop across the cable and connector in
 * the PPS operating point.  Samsung caps this board's PD path at 9 V.
 */
#define SM5440_FREQUENCY_KHZ		850
#define SM5440_FREQUENCY_SIOP2_KHZ	650
#define SM5440_FREQUENCY_SIOP1_KHZ	450
#define SM5440_SIOP_LEV1_MA		1100
#define SM5440_SIOP_LEV2_MA		1700
#define SM5440_R_TTL_MILLIOHM		320
#define SM5440_EXTRA_HEADROOM_MV	200
/*
 * The vendor's own ceiling: its dc_vbus_ovp_th is 11 V and the direct-charge
 * loop never asks for more than dc_vbus_ovp_th - 500.  The operating point needs
 * that room -- at the board's 3 A the cable and connector drop alone is
 * 3 A x 320 mOhm = 960 mV on top of twice the cell voltage -- so clamping lower
 * would starve the pump exactly where the current matters.
 */
#define SM5440_MAX_PPS_MV		10500

/*
 * Direct charging is opt-in.
 *
 * The pump needs a programmable supply, so this driver re-requests a PPS
 * operating point every two seconds for as long as it runs.  On this board that
 * request path, not the pump, is the fragile part: a keep-alive Request that
 * lands while the source re-applies its output trips the chip's reverse-blocking
 * comparator (measured: INT3 bit 1 latched, CHG_ON cleared by the chip itself),
 * and after enough of those the SM5714 TCPC stops answering on i2c, after which
 * every further Request fails with -EAGAIN ("port not ready") for the rest of
 * the boot.  Meanwhile the SM5714 switching charger on the fixed 9 V contract --
 * which is what Samsung's own board data programs -- holds the same pack current
 * (measured 2.4-2.8 A at this pack voltage) with none of that churn.
 *
 * The switch is the charger driver's fast_charge attribute, which
 * gnome-gts9wifi and /usr/libexec/gts9wifi-device-control drive: turning it off
 * hands the pack straight back to the switching path, which is what a stock
 * tablet uses.
 */
int sm5714_battery_set_direct_charge(bool active);
bool sm5714_battery_fast_charge_enabled(void);

struct sm5440_direct {
	struct device *dev;
	struct i2c_client *client;
	struct power_supply *tcpm;
	struct power_supply *battery;
	struct delayed_work work;
	int target_mv;
	int target_ma;
	unsigned int pps_ticks;
	unsigned int fails;
	bool active;
	bool suspending;
	struct notifier_block pm_nb;
};

static int sm5440_update_bits(struct sm5440_direct *sm, u8 reg, u8 mask,
			      u8 val)
{
	int old;

	old = i2c_smbus_read_byte_data(sm->client, reg);
	if (old < 0)
		return old;

	return i2c_smbus_write_byte_data(sm->client, reg,
					 (old & ~mask) | (val & mask));
}

static int sm5440_read_adc_pair(struct sm5440_direct *sm, u8 reg)
{
	int high, low;

	high = i2c_smbus_read_byte_data(sm->client, reg);
	if (high < 0)
		return high;
	low = i2c_smbus_read_byte_data(sm->client, reg + 1);
	if (low < 0)
		return low;

	return (high << 5) | (low >> 3);
}

static int sm5440_adc_vbus_mv(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_VBUS1);

	return raw < 0 ? raw : 4096 + raw;
}

static int sm5440_adc_ibus_ma(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_IBUS1);

	return raw < 0 ? raw : (raw * 625) / 1000;
}

static int sm5440_adc_vbat_mv(struct sm5440_direct *sm)
{
	int raw = sm5440_read_adc_pair(sm, SM5440_REG_ADC_VBAT1);

	return raw < 0 ? raw : 2048 + (raw * 500) / 1000;
}

static int sm5440_adc_die_temp(struct sm5440_direct *sm)
{
	int raw = i2c_smbus_read_byte_data(sm->client,
					   SM5440_REG_ADC_DIETEMP);

	return raw < 0 ? raw : 225 + raw * 5;
}

static int sm5440_psy_get(struct power_supply *psy,
			  enum power_supply_property prop)
{
	union power_supply_propval val;
	int ret;

	ret = power_supply_get_property(psy, prop, &val);
	return ret ? ret : val.intval;
}

static int sm5440_psy_set(struct power_supply *psy,
			  enum power_supply_property prop, int value)
{
	union power_supply_propval val = { .intval = value };

	return power_supply_set_property(psy, prop, &val);
}

static int sm5440_psy_retry(struct sm5440_direct *sm,
			    enum power_supply_property prop, int value)
{
	int ret = -EAGAIN;
	int i;

	for (i = 0; i < SM5440_PD_RETRIES && ret == -EAGAIN; i++) {
		if (i)
			msleep(SM5440_PD_RETRY_MS);
		ret = sm5440_psy_set(sm->tcpm, prop, value);
	}

	return ret;
}

/*
 * The pump halves the bus, so the operating point has to carry twice the cell
 * voltage plus the drop across the cable and connector (r_ttl on this board)
 * plus a small margin, exactly as the vendor loop computes it.
 */
static int sm5440_pps_target_mv(int ma, int vbat_uv)
{
	int headroom = DIV_ROUND_UP(ma * SM5440_R_TTL_MILLIOHM, 1000) +
		       SM5440_EXTRA_HEADROOM_MV;
	int mv = DIV_ROUND_UP((vbat_uv / 1000) * 2 + headroom,
			      SM5440_PPS_V_STEP_MV) * SM5440_PPS_V_STEP_MV;

	return clamp(mv, 8200, SM5440_MAX_PPS_MV);
}

/*
 * The chip's own input limit, kept a little above the requested PPS current so
 * the pump is not the thing throttling the contract, the way the vendor does it
 * (ibuslim = ci_gl + SM5440_CI_OFFSET).  IBUSCNTL encodes 50 mA per step up to
 * 0x7f, i.e. 6350 mA.
 */
static int sm5440_set_ibus_limit(struct sm5440_direct *sm, int ma)
{
	int limit = clamp_val(ma + SM5440_IBUS_MARGIN_MA, 0, 6350);

	return i2c_smbus_write_byte_data(sm->client, SM5440_REG_IBUSCNTL,
					 limit / 50);
}

/*
 * Give the pump as much current as the adapter will grant.
 *
 * tcpm_aug_set_op_curr() answers -EINVAL both for a current above the source's
 * PPS APDO and for one whose power lands under the port's operating_snk_mw
 * (15 W on this board), and -EAGAIN while the port is not ready -- so walking
 * down from the board's budget discovers the adapter's real limit without the
 * driver having to read the source capabilities out of sysfs.  A rejected step is
 * answered before any PD traffic, so walking costs no bus activity, and the pump
 * is still off here, so the negotiations it does trigger cannot trip REVBLK.
 */
static int sm5440_negotiate_pps(struct sm5440_direct *sm, int vbat_uv,
				int *target_ma, int *target_mv)
{
	int ma = clamp_val(max_pps_ma, SM5440_MIN_PPS_MA, SM5440_PPS_CAP_MA);
	int ret;

	ret = sm5440_psy_retry(sm, POWER_SUPPLY_PROP_ONLINE, 2);
	if (ret)
		return ret;

	for (; ma >= SM5440_MIN_PPS_MA; ma -= SM5440_PPS_STEP_MA) {
		ret = sm5440_psy_retry(sm, POWER_SUPPLY_PROP_CURRENT_NOW,
				       ma * 1000);
		if (!ret || ret != -EINVAL)
			break;
	}
	if (ret)
		goto fixed;

	*target_ma = ma;
	*target_mv = sm5440_pps_target_mv(ma, vbat_uv);
	ret = sm5440_psy_retry(sm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
			       *target_mv * 1000);
	if (ret)
		goto fixed;

	dev_info(sm->dev, "PPS contract requested: %d mV/%d mA\n",
		 *target_mv, *target_ma);
	return 0;

fixed:
	sm5440_psy_retry(sm, POWER_SUPPLY_PROP_ONLINE, 1);
	return ret;
}

/*
 * Keep the operating point alive.
 *
 * Every power_supply property write is its own Power Negotiation and each one
 * re-applies the source's output voltage, so the refresh sends as few of them as
 * it can: the voltage only when the pack has moved the operating point by a step
 * (the only way it changes), the current every time.  The pump is parked across
 * whichever negotiation happens -- see sm5440_renegotiate_pps().
 */
static int sm5440_refresh_pps(struct sm5440_direct *sm)
{
	int battery_uv, target_mv;
	int ret;

	battery_uv = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_VOLTAGE_NOW);
	if (battery_uv < 0)
		return battery_uv;

	target_mv = sm5440_pps_target_mv(sm->target_ma, battery_uv);
	if (abs(target_mv - sm->target_mv) >= SM5440_PPS_V_STEP_MV) {
		ret = sm5440_psy_retry(sm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
				       target_mv * 1000);
		if (ret)
			return ret;
		sm->target_mv = target_mv;
	}

	return sm5440_psy_retry(sm, POWER_SUPPLY_PROP_CURRENT_NOW,
				sm->target_ma * 1000);
}

static int sm5440_set_freq(struct sm5440_direct *sm, int khz)
{
	return i2c_smbus_write_byte_data(sm->client, SM5440_REG_CNTL7,
					 (khz - 250) / 50);
}

static int sm5440_select_freq(struct sm5440_direct *sm, int ma)
{
	if (ma <= SM5440_SIOP_LEV1_MA)
		return sm5440_set_freq(sm, SM5440_FREQUENCY_SIOP1_KHZ);
	if (ma <= SM5440_SIOP_LEV2_MA)
		return sm5440_set_freq(sm, SM5440_FREQUENCY_SIOP2_KHZ);

	return sm5440_set_freq(sm, SM5440_FREQUENCY_KHZ);
}

static int sm5440_pump_off(struct sm5440_direct *sm)
{
	return sm5440_update_bits(sm, SM5440_REG_CNTL5,
				  SM5440_CNTL5_OP_MODE_MASK, 0);
}

static int sm5440_pump_on(struct sm5440_direct *sm)
{
	int status3 = 0;
	int i;
	int ret;

	ret = sm5440_update_bits(sm, SM5440_REG_CNTL5,
				 SM5440_CNTL5_OP_MODE_MASK,
				 SM5440_CNTL5_CHG_ON);
	if (ret)
		return ret;

	/*
	 * VBUSPOK is set as soon as the pump starts pulling the bus down, which is
	 * well before the 100 ms this used to sleep unconditionally.  Poll for it
	 * instead, keeping the old worst case as the loop bound.
	 */
	for (i = 0; i < 5; i++) {
		msleep(20);
		status3 = i2c_smbus_read_byte_data(sm->client,
						   SM5440_REG_STATUS3);
		if (status3 < 0)
			return status3;
		if (status3 & SM5440_STATUS3_VBUSPOK)
			return 0;
	}

	return -ENOLINK;
}

/*
 * A PPS power_supply write completes before the adapter has necessarily
 * reached the requested voltage, and the chip's reverse-blocking comparator
 * latches REVBLK if the pump is switching across that step.  Let the SM5440's
 * own ADC prove the physical bus is ready before touching CHG_ON.
 */
static int sm5440_wait_vbus_settled(struct sm5440_direct *sm, int target_mv)
{
	int vbus_mv = 0;
	int i;

	/*
	 * The pump is parked while this runs, so every millisecond here is charge
	 * current the pack does not get.  The chip's bus ADC is already averaging
	 * (see ADCCNTL1 in hw_init) and the source has normally re-applied its
	 * output by now, so give it one conversion and then look, rather than
	 * sleeping a fixed 100 ms per attempt and waiting up to three seconds.
	 */
	for (i = 0; i < 30; i++) {
		msleep(i ? 50 : 20);
		vbus_mv = sm5440_adc_vbus_mv(sm);
		if (vbus_mv < 0)
			return vbus_mv;
		if (vbus_mv >= target_mv - 500)
			return 0;
	}

	dev_warn(sm->dev, "PPS bus did not settle: target=%dmV measured=%dmV\n",
		 target_mv, vbus_mv);
	return -ETIMEDOUT;
}

/*
 * Keep the programmable contract alive without killing the pump.
 *
 * A PPS source re-applies its output voltage on every Request, and that step is
 * enough to drive the 2:1 pump's output above its input for an instant.  The
 * chip then latches REVBLK and clears CHG_ON by itself, so the keep-alive used
 * to end direct charging every couple of seconds and hand the battery back to
 * the 9 V switching charger until the retry.  Park the pump across the
 * re-negotiation and re-arm it once the bus has settled again -- the same rule
 * sm5440_start() applies to the first contract.
 */
static int sm5440_renegotiate_pps(struct sm5440_direct *sm)
{
	int ret;

	ret = sm5440_pump_off(sm);
	if (ret)
		return ret;

	ret = sm5440_refresh_pps(sm);
	if (ret)
		return ret;

	ret = sm5440_wait_vbus_settled(sm, sm->target_mv);
	if (ret)
		return ret;

	return sm5440_pump_on(sm);
}

static void sm5440_log_faults(struct sm5440_direct *sm)
{
	static const struct {
		u8 bit;
		bool int3;
		const char *name;
	} faults[] = {
		{ SM5440_INT1_VOUTOVP, false, "VOUT_OVP" },
		{ SM5440_INT1_VBATOVP, false, "VBAT_OVP" },
		{ SM5440_INT3_VBUSOVP, true, "VBUS_OVP" },
		{ SM5440_INT3_VBUSUVLO, true, "VBUS_UVLO" },
		{ SM5440_INT3_THEMSHDN, true, "THERMAL_SHUTDOWN" },
		{ SM5440_INT3_STUP_FAIL, true, "STARTUP_FAIL" },
		{ SM5440_INT3_REVBLK, true, "REVERSE_BLOCKING" },
		{ SM5440_INT3_CFLY_SHORT, true, "FLYING_CAP_SHORT" },
		{ }
	};
	int int1, int3;
	int i;

	/* Read-to-clear: harvest these before the next start wipes them. */
	int1 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_INT1);
	int3 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_INT3);

	dev_warn(sm->dev, "pump off: INT1=%#x INT3=%#x\n", int1, int3);
	for (i = 0; faults[i].name; i++) {
		int reg = faults[i].int3 ? int3 : int1;

		if (reg > 0 && (reg & faults[i].bit))
			dev_warn(sm->dev, "  latched fault: %s\n",
				 faults[i].name);
	}
}

static void sm5440_restore_switching(struct sm5440_direct *sm)
{
	sm5440_update_bits(sm, SM5440_REG_CNTL5,
			   SM5440_CNTL5_OP_MODE_MASK, 0);
	sm5440_update_bits(sm, SM5440_REG_ADCCNTL1,
			   SM5440_ADCCNTL1_ENABLE, 0);
	sm5440_update_bits(sm, SM5440_REG_CNTL1,
			   SM5440_CNTL1_WDT_EN, 0);
	/*
	 * Back to the fixed contract.  If this is the call that keeps failing, the
	 * port is wedged inside TCPM and only a re-plug or reboot clears it -- but
	 * retrying costs nothing and it is the only way out from here.
	 */
	sm5440_psy_retry(sm, POWER_SUPPLY_PROP_ONLINE, 1);
	sm5714_battery_set_direct_charge(false);
	sm->pps_ticks = 0;
	sm->active = false;
}

static void sm5440_put_power_supply(void *data)
{
	power_supply_put(data);
}

static int sm5440_hw_init(struct sm5440_direct *sm)
{
	int reg;
	int ret;
	int i;

	ret = i2c_smbus_write_byte_data(sm->client, SM5440_REG_CNTL1,
					 SM5440_CNTL1_SW_RESET);
	if (ret)
		return ret;
	for (i = 0; i < 255; i++) {
		usleep_range(1000, 2000);
		reg = i2c_smbus_read_byte_data(sm->client, SM5440_REG_CNTL1);
		if (reg < 0)
			return reg;
		if (!(reg & SM5440_CNTL1_SW_RESET))
			break;
	}
	if (i == 255)
		return -ETIMEDOUT;

#define SM5440_WRITE(_reg, _val) do {					\
	ret = i2c_smbus_write_byte_data(sm->client, (_reg), (_val));	\
	if (ret)							\
		return ret;						\
} while (0)

	SM5440_WRITE(SM5440_REG_CNTL1, SM5440_CNTL1_WDT_30S);
	SM5440_WRITE(SM5440_REG_CNTL2, 0xf2);
	SM5440_WRITE(SM5440_REG_CNTL3, 0xb8);
	SM5440_WRITE(SM5440_REG_CNTL4, 0xff);
	SM5440_WRITE(SM5440_REG_CNTL6, 0x09);
	/* CNTL7 (switching frequency) is programmed per charge current in
	 * sm5440_start(), the way the vendor driver does it. */
	SM5440_WRITE(SM5440_REG_VBUSCNTL, 0x07);
	SM5440_WRITE(SM5440_REG_VBATCNTL,
		     ((SM5440_VBATREG_MV - 3800) * 10) / 125);
	SM5440_WRITE(SM5440_REG_VOUTCNTL, 0x3f);
	SM5440_WRITE(SM5440_REG_IBUSCNTL, SM5440_INITIAL_IBUS_MA / 50);
	SM5440_WRITE(SM5440_REG_PRTNCNTL, 0xfe);
	SM5440_WRITE(SM5440_REG_THEMCNTL1, 0x0c);
	SM5440_WRITE(SM5440_REG_ADCCNTL1,
		     SM5440_ADCCNTL1_AVG_32 |
		     SM5440_ADCCNTL1_CONTINUOUS |
		     SM5440_ADCCNTL1_ENABLE);
	SM5440_WRITE(SM5440_REG_ADCCNTL2, 0xdf);
#undef SM5440_WRITE

	/* Reading the four interrupt latches clears stale bootloader events. */
	for (i = 0; i < 4; i++) {
		ret = i2c_smbus_read_byte_data(sm->client, i);
		if (ret < 0)
			return ret;
	}

	return 0;
}

static int sm5440_start(struct sm5440_direct *sm)
{
	int battery_uv, target_mv, target_ma;
	int ret;

	battery_uv = sm5440_psy_get(sm->battery,
				    POWER_SUPPLY_PROP_VOLTAGE_NOW);
	if (battery_uv < 0)
		return battery_uv;

	/*
	 * Open the SM5714 switching path while VBUS is still at its safe fixed
	 * 9 V contract.  Only then may the direct charger leave that contract
	 * for a programmable one.
	 */
	ret = sm5714_battery_set_direct_charge(true);
	if (ret)
		return ret;

	ret = sm5440_hw_init(sm);
	if (ret)
		goto restore;

	ret = sm5440_negotiate_pps(sm, battery_uv, &target_ma, &target_mv);
	if (ret)
		goto restore;

	ret = sm5440_select_freq(sm, target_ma);
	if (ret)
		goto restore;

	ret = sm5440_set_ibus_limit(sm, target_ma);
	if (ret)
		goto restore;

	ret = sm5440_wait_vbus_settled(sm, target_mv);
	if (ret)
		goto restore;

	ret = sm5440_update_bits(sm, SM5440_REG_CNTL1,
				 SM5440_CNTL1_WDT_EN,
				 SM5440_CNTL1_WDT_EN);
	if (ret)
		goto restore;

	ret = sm5440_pump_on(sm);
	if (ret)
		goto restore;

	sm->active = true;
	sm->target_mv = target_mv;
	sm->target_ma = target_ma;
	sm->pps_ticks = 0;
	dev_info(sm->dev,
		 "direct charge started: PPS %d mV/%d mA, ibus limit %d mA\n",
		 target_mv, target_ma,
		 clamp_val(target_ma + SM5440_IBUS_MARGIN_MA, 0, 6350));
	return 0;

restore:
	sm5440_restore_switching(sm);
	return ret;
}

static bool sm5440_eligible(struct sm5440_direct *sm)
{
	int capacity, online, temp, voltage;

	online = sm5440_psy_get(sm->tcpm, POWER_SUPPLY_PROP_ONLINE);
	capacity = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_CAPACITY);
	temp = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_TEMP);
	voltage = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_VOLTAGE_NOW);

	return online > 0 && capacity >= 5 && capacity < 90 &&
	       temp >= 100 && temp < 420 &&
	       voltage >= 3500000 && voltage < 4350000;
}

/*
 * A pump that cannot hold is worse than no pump: it hands the pack back to the
 * switching charger and re-negotiates PPS over and over.  Back off exponentially
 * and then stay quiet for a while instead of cycling.
 */
static unsigned long sm5440_backoff(struct sm5440_direct *sm)
{
	if (sm->fails < SM5440_MAX_FAILS)
		sm->fails++;

	if (sm->fails >= SM5440_MAX_FAILS) {
		dev_warn(sm->dev,
			 "direct charging is not holding; retrying in %d s\n",
			 SM5440_QUIET_RETRY_MS / 1000);
		return msecs_to_jiffies(SM5440_QUIET_RETRY_MS);
	}

	return msecs_to_jiffies(min(SM5440_RETRY_MS << sm->fails,
				    SM5440_MAX_RETRY_MS));
}

static void sm5440_work(struct work_struct *work)
{
	struct sm5440_direct *sm =
		container_of(to_delayed_work(work), struct sm5440_direct, work);
	unsigned long delay = msecs_to_jiffies(SM5440_POLL_MS);
	int capacity, die_temp, ibus, op_mode, pack_temp, status3;
	int vbat, vbus;
	int ret;

	if (!sm->active) {
		/*
		 * Opt-in: the SM5714 switching charger owns the pack on the fixed
		 * 9 V contract until fast charging is switched on.
		 */
		if (!sm5714_battery_fast_charge_enabled()) {
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
			goto out;
		}
		if (!sm5440_eligible(sm)) {
			delay = msecs_to_jiffies(SM5440_RETRY_MS);
			goto out;
		}
		ret = sm5440_start(sm);
		if (ret) {
			dev_warn(sm->dev, "direct-charge start failed: %d\n", ret);
			delay = sm5440_backoff(sm);
			goto out;
		}
		sm->fails = 0;
		goto out;
	}

	/* The switch can go off while the pump runs: hand the pack back. */
	if (!sm5714_battery_fast_charge_enabled()) {
		sm5440_log_faults(sm);
		sm5440_restore_switching(sm);
		dev_info(sm->dev,
			 "fast charging off: back to the fixed contract\n");
		delay = msecs_to_jiffies(SM5440_RETRY_MS);
		goto out;
	}

	/*
	 * PPS sources leave the programmable contract unless the sink refreshes
	 * its Request periodically. Samsung's downstream loop does this every
	 * 2.5 seconds; without it the EP-T4510 fell back after about five
	 * seconds and the resulting VBUS step tripped REVBLK.  Four seconds keeps
	 * a margin under that fallback while halving how often the pump has to be
	 * parked for the negotiation -- parked time is charge current the pack
	 * never gets, and the parked window itself is kept as short as the chip's
	 * bus ADC allows (see sm5440_wait_vbus_settled / sm5440_pump_on).
	 */
	if (++sm->pps_ticks >= SM5440_REFRESH_TICKS) {
		sm->pps_ticks = 0;
		ret = sm5440_renegotiate_pps(sm);
		if (ret) {
			sm5440_log_faults(sm);
			dev_warn(sm->dev, "failed to refresh PPS: %d\n", ret);
			sm5440_restore_switching(sm);
			delay = sm5440_backoff(sm);
			goto out;
		}
	}

	capacity = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_CAPACITY);
	pack_temp = sm5440_psy_get(sm->battery, POWER_SUPPLY_PROP_TEMP);
	op_mode = i2c_smbus_read_byte_data(sm->client, SM5440_REG_CNTL5);
	status3 = i2c_smbus_read_byte_data(sm->client, SM5440_REG_STATUS3);
	vbus = sm5440_adc_vbus_mv(sm);
	ibus = sm5440_adc_ibus_ma(sm);
	vbat = sm5440_adc_vbat_mv(sm);
	die_temp = sm5440_adc_die_temp(sm);

	if (capacity < 0 || pack_temp < 0 || op_mode < 0 || status3 < 0 ||
	    vbus < 0 || ibus < 0 || vbat < 0 || die_temp < 0 ||
	    capacity >= 90 || pack_temp >= 450 ||
	    !(op_mode & SM5440_CNTL5_CHG_ON) ||
	    !(status3 & SM5440_STATUS3_VBUSPOK) ||
	    vbus > 10800 || vbat > 4450 || die_temp >= 1100) {
		dev_warn(sm->dev,
			 "stopping direct charge: cap=%d temp=%d mode=%#x "
			 "st3=%#x vbus=%d ibus=%d vbat=%d die=%d\n",
			 capacity, pack_temp, op_mode, status3,
			 vbus, ibus, vbat, die_temp);
		sm5440_log_faults(sm);
		sm5440_restore_switching(sm);
		delay = sm5440_backoff(sm);
		goto out;
	}

	/* Rewriting CNTL1 services the hardware watchdog. */
	ret = sm5440_update_bits(sm, SM5440_REG_CNTL1,
				 SM5440_CNTL1_WDT_EN,
				 SM5440_CNTL1_WDT_EN);
	if (ret) {
		sm5440_restore_switching(sm);
		delay = sm5440_backoff(sm);
		goto out;
	}

	/* A complete, healthy poll: forget earlier failures. */
	sm->fails = 0;

	dev_info_ratelimited(sm->dev,
			     "direct: pack=%d.%dC vbus=%dmV ibus=%dmA "
			     "vbat=%dmV die=%d.%dC\n",
			     pack_temp / 10, abs(pack_temp % 10),
			     vbus, ibus, vbat,
			     die_temp / 10, abs(die_temp % 10));
out:
	/* The PM notifier owns rescheduling while the system is suspending. */
	if (!sm->suspending)
		schedule_delayed_work(&sm->work, delay);
}

static void sm5440_cancel_work(void *data)
{
	struct sm5440_direct *sm = data;

	cancel_delayed_work_sync(&sm->work);
	if (sm->active)
		sm5440_restore_switching(sm);
}

static void sm5440_unregister_pm(void *data)
{
	struct sm5440_direct *sm = data;

	unregister_pm_notifier(&sm->pm_nb);
}

/*
 * The i2c adapter this charger sits on is suspended with the system, so the poll
 * must neither run nor be scheduled once the tablet is going down: a poll during
 * suspend trips the i2c core's "Transfer while suspended" warning, and a pump
 * left running would lose its PPS contract anyway because nothing refreshes it
 * while the bus is gone.  Park the pump, hand the pack back to the switching
 * charger, and start polling again after resume.
 */
static int sm5440_pm_notify(struct notifier_block *nb, unsigned long action,
			    void *data)
{
	struct sm5440_direct *sm = container_of(nb, struct sm5440_direct, pm_nb);

	switch (action) {
	case PM_SUSPEND_PREPARE:
		sm->suspending = true;
		cancel_delayed_work_sync(&sm->work);
		if (sm->active) {
			sm5440_pump_off(sm);
			sm5440_restore_switching(sm);
			dev_info(sm->dev,
				 "system suspending: back to the fixed contract\n");
		}
		break;
	case PM_POST_SUSPEND:
		sm->suspending = false;
		schedule_delayed_work(&sm->work,
				      msecs_to_jiffies(SM5440_POLL_MS));
		break;
	}

	return NOTIFY_DONE;
}

static int sm5440_probe(struct i2c_client *client)
{
	struct sm5440_direct *sm;
	int id;
	int ret;

	if (!i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_BYTE_DATA))
		return -EOPNOTSUPP;

	sm = devm_kzalloc(&client->dev, sizeof(*sm), GFP_KERNEL);
	if (!sm)
		return -ENOMEM;
	sm->dev = &client->dev;
	sm->client = client;
	i2c_set_clientdata(client, sm);

	id = i2c_smbus_read_byte_data(client, SM5440_REG_DEVICEID);
	if (id < 0)
		return dev_err_probe(sm->dev, id, "cannot read device ID\n");
	if ((id & 0x0f) != 1)
		return dev_err_probe(sm->dev, -ENODEV,
				     "unexpected device ID %#x\n", id);

	sm->tcpm = devm_power_supply_get_by_reference(sm->dev,
						      "tcpm-power-supply");
	if (IS_ERR(sm->tcpm))
		return dev_err_probe(sm->dev, PTR_ERR(sm->tcpm),
				     "cannot get TCPM power supply\n");
	if (!sm->tcpm)
		return dev_err_probe(sm->dev, -EPROBE_DEFER,
				     "TCPM power supply is not ready\n");

	sm->battery = power_supply_get_by_name("sm5714-battery");
	if (!sm->battery)
		return dev_err_probe(sm->dev, -EPROBE_DEFER,
				     "battery power supply is not ready\n");
	ret = devm_add_action_or_reset(sm->dev, sm5440_put_power_supply,
				       sm->battery);
	if (ret)
		return ret;

	INIT_DELAYED_WORK(&sm->work, sm5440_work);
	ret = devm_add_action_or_reset(sm->dev, sm5440_cancel_work, sm);
	if (ret)
		return ret;

	sm->pm_nb.notifier_call = sm5440_pm_notify;
	ret = register_pm_notifier(&sm->pm_nb);
	if (ret)
		return dev_err_probe(sm->dev, ret,
				     "cannot register the PM notifier\n");
	ret = devm_add_action_or_reset(sm->dev, sm5440_unregister_pm, sm);
	if (ret)
		return ret;

	schedule_delayed_work(&sm->work, msecs_to_jiffies(10000));

	dev_info(sm->dev,
		 "SM5440 direct charger device ID %#x, fast charging %s (cap %u mA)\n",
		 id, sm5714_battery_fast_charge_enabled() ? "on" : "off",
		 max_pps_ma);
	return 0;
}

static const struct of_device_id sm5440_of_match[] = {
	{ .compatible = "siliconmitus,sm5440" },
	{ }
};
MODULE_DEVICE_TABLE(of, sm5440_of_match);

static struct i2c_driver sm5440_driver = {
	.driver = {
		.name = "sm5440-direct",
		.of_match_table = sm5440_of_match,
	},
	.probe = sm5440_probe,
};
module_i2c_driver(sm5440_driver);

MODULE_DESCRIPTION("Silicon Mitus SM5440 direct charger for Samsung SM-X710");
MODULE_LICENSE("GPL");
