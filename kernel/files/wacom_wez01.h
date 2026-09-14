/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_WACOM_WEZ01_H
#define _LINUX_WACOM_WEZ01_H

#include <linux/kconfig.h>

#include <linux/types.h>

#if IS_REACHABLE(CONFIG_TOUCHSCREEN_WACOM_WEZ01)
bool wacom_wez01_should_suppress_touch(void);
#else
static inline bool wacom_wez01_should_suppress_touch(void)
{
	return false;
}
#endif

#endif /* _LINUX_WACOM_WEZ01_H */