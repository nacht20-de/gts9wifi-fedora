#!/bin/bash
# Prepare the mainline kernel tree for gts9wifi, translated 1:1 from the
# postmarketOS APKBUILD prepare() (linux-samsung-gts9wifi-mainline).
#
# Usage: prepare.sh <linux-source-tree>
# Run from the repo root (this file lives in kernel/).

set -euo pipefail

tree="${1:?usage: prepare.sh <linux-tree>}"
here="$(cd "$(dirname "$0")" && pwd)"

cd "$tree"

# The 17 port patches (abuild applied all *.patch with -p1).
for p in "$here"/patches/*.patch; do
    patch -p1 --forward < "$p"
done

# Board DTS.
cp "$here/files/sm8550-samsung-gts9wifi.dts" arch/arm64/boot/dts/qcom/
if ! grep -q 'sm8550-samsung-gts9wifi.dtb' arch/arm64/boot/dts/qcom/Makefile; then
    # add-gts9wifi-dtb.patch normally handles this; keep the guard anyway.
    grep -q 'gts9wifi' arch/arm64/boot/dts/qcom/Makefile || \
        echo 'dtb-$(CONFIG_ARCH_QCOM) += sm8550-samsung-gts9wifi.dtb' \
            >> arch/arm64/boot/dts/qcom/Makefile
fi

# Out-of-tree drivers: drop in the source and register in Kconfig/Makefile.
register_driver() {
    local src="$1" dest="$2" kcfg="$3" cfgblock="$4" objline="$5"
    cp "$here/files/$src" "$dest/"
    if ! grep -q "${cfgblock%% *}" "$kcfg"; then
        printf '\n%s\n' "$cfgblock" >> "$kcfg"
    fi
    grep -q "$(basename "${objline%% *}")" "$(dirname "$kcfg")/Makefile" || \
        echo "$objline" >> "$(dirname "$kcfg")/Makefile"
}

# ANA38407 DSI panel.
cp "$here/files/panel-samsung-ana38407.c" drivers/gpu/drm/panel/
grep -q 'DRM_PANEL_SAMSUNG_ANA38407' drivers/gpu/drm/panel/Kconfig || sed -i '/^endmenu$/i \
config DRM_PANEL_SAMSUNG_ANA38407\
\ttristate "Samsung ANA38407 AMSA10FA01 (gts9) DSI command-mode panel"\
\tdepends on OF\
\tdepends on DRM_MIPI_DSI\
\tdepends on BACKLIGHT_CLASS_DEVICE\
' drivers/gpu/drm/panel/Kconfig
grep -q 'panel-samsung-ana38407.o' drivers/gpu/drm/panel/Makefile || \
    echo 'obj-$(CONFIG_DRM_PANEL_SAMSUNG_ANA38407) += panel-samsung-ana38407.o' >> drivers/gpu/drm/panel/Makefile

# STM FTS1BA90A touchscreen.
cp "$here/files/fts1ba90a.c" drivers/input/touchscreen/
grep -q 'TOUCHSCREEN_FTS1BA90A' drivers/input/touchscreen/Kconfig || sed -i '/^endif$/i \
config TOUCHSCREEN_FTS1BA90A\
\ttristate "STMicroelectronics FTS1BA90A touchscreen"\
\tdepends on OF && I2C\
\tselect INPUT_MT\
' drivers/input/touchscreen/Kconfig
grep -q 'fts1ba90a.o' drivers/input/touchscreen/Makefile || \
    echo 'obj-$(CONFIG_TOUCHSCREEN_FTS1BA90A) += fts1ba90a.o' >> drivers/input/touchscreen/Makefile

# Wacom WEZ01 S Pen digitizer.
cp "$here/files/wacom-wez01.c" drivers/input/touchscreen/
grep -q 'TOUCHSCREEN_WACOM_WEZ01' drivers/input/touchscreen/Kconfig || sed -i '/^endif$/i \
config TOUCHSCREEN_WACOM_WEZ01\
\ttristate "Wacom WEZ01 S Pen digitizer"\
\tdepends on OF && I2C\
' drivers/input/touchscreen/Kconfig
grep -q 'wacom-wez01.o' drivers/input/touchscreen/Makefile || \
    echo 'obj-$(CONFIG_TOUCHSCREEN_WACOM_WEZ01) += wacom-wez01.o' >> drivers/input/touchscreen/Makefile

# Silicon Mitus SM5714 charger / fuel gauge.
cp "$here/files/sm5714_battery.c" drivers/power/supply/
grep -q 'BATTERY_SM5714' drivers/power/supply/Kconfig || sed -i '/^endif # POWER_SUPPLY$/i \
config BATTERY_SM5714\
\ttristate "Silicon Mitus SM5714 charger and fuel gauge"\
\tdepends on I2C\
\tdepends on IIO\
' drivers/power/supply/Kconfig
grep -q 'sm5714_battery.o' drivers/power/supply/Makefile || \
    echo 'obj-$(CONFIG_BATTERY_SM5714)	+= sm5714_battery.o' >> drivers/power/supply/Makefile

# SM5440 2:1 direct charger.
cp "$here/files/sm5440_direct.c" drivers/power/supply/
grep -q 'CHARGER_SM5440_DIRECT' drivers/power/supply/Kconfig || sed -i '/^endif # POWER_SUPPLY$/i \
config CHARGER_SM5440_DIRECT\
\ttristate "Silicon Mitus SM5440 direct charger for Samsung SM-X710"\
\tdepends on I2C\
\tdepends on BATTERY_SM5714\
' drivers/power/supply/Kconfig
grep -q 'sm5440_direct.o' drivers/power/supply/Makefile || \
    echo 'obj-$(CONFIG_CHARGER_SM5440_DIRECT)	+= sm5440_direct.o' >> drivers/power/supply/Makefile

# SM5714 Type-C/PD transport.
cp "$here/files/sm5714_usbpd.c" drivers/usb/typec/tcpm/
grep -q 'TYPEC_SM5714' drivers/usb/typec/tcpm/Kconfig || sed -i '/^endif # TYPEC_TCPM$/i \
config TYPEC_SM5714\
\ttristate "Silicon Mitus SM5714 USB Type-C and PD controller"\
\tdepends on I2C\
\tdepends on TYPEC_TCPM\
\tdepends on BATTERY_SM5714\
' drivers/usb/typec/tcpm/Kconfig
grep -q 'sm5714_usbpd.o' drivers/usb/typec/tcpm/Makefile || \
    echo 'obj-$(CONFIG_TYPEC_SM5714)	+= sm5714_usbpd.o' >> drivers/usb/typec/tcpm/Makefile

# Parade PS5169 Type-C redriver.
cp "$here/files/ps5169.c" drivers/usb/typec/mux/
grep -q 'TYPEC_MUX_PS5169' drivers/usb/typec/mux/Kconfig || cat >> drivers/usb/typec/mux/Kconfig <<-'EOF'

config TYPEC_MUX_PS5169
	tristate "Parade PS5169 Type-C redriver"
	depends on I2C
	depends on TYPEC
	depends on USB_ROLE_SWITCH
EOF
grep -q 'ps5169.o' drivers/usb/typec/mux/Makefile || \
    echo 'obj-$(CONFIG_TYPEC_MUX_PS5169)	+= ps5169.o' >> drivers/usb/typec/mux/Makefile

# pmOS mainline base config + gts9wifi fragment.
cp "$here/files/config-mainline.aarch64" .config
scripts/kconfig/merge_config.sh -m .config "$here/files/config-gts9wifi.fragment"
unset LDFLAGS
make ARCH=arm64 LLVM=1 olddefconfig

echo ">>> kernel tree prepared: $(make ARCH=arm64 kernelrelease 2>/dev/null || true)"
