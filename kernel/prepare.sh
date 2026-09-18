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

# The port patches (abuild applied all *.patch with -p1).
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

# Shared wacom-wez01 pen-proximity/touch-suppression header (palm rejection).
mkdir -p include/linux
cp "$here/files/wacom_wez01.h" include/linux/

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

# Hynix HI1337 camera sensor (port of the S9 Ultra mainline driver).
cp "$here/files/hi1337_gts9u.c" drivers/media/i2c/
cp "$here/files/hi1337_gts9u_tables.h" drivers/media/i2c/
grep -q 'VIDEO_HI1337_GTS9U' drivers/media/i2c/Kconfig || sed -i '/^endif # VIDEO_DEV$/i \
config VIDEO_HI1337_GTS9U\
\ttristate "Hynix HI1337 camera sensor driver (shared S9/S9 Ultra)"\
\tdepends on I2C && VIDEO_DEV\
\tdepends on MEDIA_CONTROLLER\
\tdepends on OF\
' drivers/media/i2c/Kconfig
grep -q 'hi1337_gts9u.o' drivers/media/i2c/Makefile || \
    echo 'obj-$(CONFIG_VIDEO_HI1337_GTS9U)	+= hi1337_gts9u.o' >> drivers/media/i2c/Makefile

# Dongwoon DW9808 voice-coil lens actuator.
cp "$here/files/dw9808_vcm.c" drivers/media/i2c/
grep -q 'VIDEO_DW9808_VCM' drivers/media/i2c/Kconfig || sed -i '/^endif # VIDEO_DEV$/i \
config VIDEO_DW9808_VCM\
\ttristate "DW9808 lens voice coil support"\
\tdepends on I2C && VIDEO_DEV\
\tdepends on MEDIA_CONTROLLER\
' drivers/media/i2c/Kconfig
grep -q 'dw9808_vcm.o' drivers/media/i2c/Makefile || \
    echo 'obj-$(CONFIG_VIDEO_DW9808_VCM)	+= dw9808_vcm.o' >> drivers/media/i2c/Makefile

# EgisTec EL721 fingerprint sensor (under-display, secure-world companion).
# Only the power/reset/metadata half lives in Linux: the sensor's 3.3 V rail and
# its enable line, plus Samsung's non-data ioctl ABI on /dev/esfp0.  Capture,
# matching and templates are inside the signed dualfp TrustZone app, so this
# driver deliberately exposes no frame path.  Built as a module so the reader
# can be brought up on a running tablet; it registers its own platform device
# because Samsung's ABL does not tolerate the GPIO description in the DTB.
cp "$here/files/egis_el721.c" drivers/misc/
grep -q 'FINGERPRINT_EL721' drivers/misc/Kconfig || sed -i '/^endmenu$/i \
config FINGERPRINT_EL721\
\ttristate "EgisTec EL721 fingerprint sensor (secure-world companion)"\
\tdepends on OF\
' drivers/misc/Kconfig
grep -q 'egis_el721.o' drivers/misc/Makefile || \
    echo 'obj-$(CONFIG_FINGERPRINT_EL721)\t+= egis_el721.o' >> drivers/misc/Makefile

# Samsung K250A secure element (snvm): the embedded SE carrying the credential
# HwVault uses to derive fingerprint template keys, reached by the EL721
# userspace stack as /dev/k250a.  The module is a self-contained eSE stack
# (ISO7816 T=1 protocol layer plus an i2c/spi HAL) that creates its own i2c
# client: Samsung's DTB leaves both the controller and the part's 1.8 V rail
# undescribed, so the driver enables qupv3_se10_i2c (i2c@888000) with an
# of_changeset and votes PM8550VS LDO G2 (cmd-db name "ldog2", 1.8 V) over the
# public RPMh interface.  Module-only so the secure element can be brought up,
# and rolled back, on a running tablet.
mkdir -p drivers/misc/snvm
cp -r "$here/files/snvm/." drivers/misc/snvm/
grep -q 'STAR_K250A_LEGO' drivers/misc/Kconfig || sed -i '/^endmenu$/i \
config STAR_K250A_LEGO\
\ttristate "Samsung K250A secure element (snvm)"\
\tdepends on I2C && OF && ARCH_QCOM\
\
config SEC_SNVM_WAKELOCK_METHOD\
\tint "snvm wakelock method"\
\tdefault 0\
' drivers/misc/Kconfig
grep -q 'misc/snvm' drivers/misc/Makefile || \
    echo 'obj-$(CONFIG_STAR_K250A_LEGO)\t+= snvm/' >> drivers/misc/Makefile

# Secure-processor (SPSS/SPU) stack.  The fingerprint stack's Keymaster/StrongBox
# services run on Samsung's secure processor, for which upstream has no driver
# at all; this is the sibling Galaxy Tab S9 Ultra port's stack, ported as
# modules so the SPU can be brought up (and rolled back) on a running tablet.
# The SPU firmware region and both SPU shared-memory regions are already
# reserved by sm8550.dtsi, and qcom_spss publishes its own DT node, so no board
# DTS change is needed.  Pieces:
#   qcom_spss          PAS remoteproc: boots spss1p.mdt (PAS id 14) and creates
#                      the spcom/spss_utils child devices
#   qcom_glink_spss    GLINK transport the remoteproc links against
#   spcom              /dev/spcom, the channel to the SPU
#   spss_utils         /dev/spss_utils, SPU provisioning/event interface
#   qcom_spss_irq      /dev/qsee_ipc_irq_spss for the SPL listener
#                      (IPCC client 16, signal 1, rising edge)
#   qcom_sp_hlos_heap  DMA-buf heap the SPU shares buffers through
cp "$here/files/spu/qcom_spss.c" drivers/remoteproc/
cp "$here/files/spu/qcom_glink_spss.c" drivers/rpmsg/
cp "$here/files/spu/spcom.c" "$here/files/spu/spss_utils.c" \
   "$here/files/spu/qcom_spss_irq.c" drivers/soc/qcom/
cp "$here/files/spu/qcom_sp_hlos_heap.c" drivers/dma-buf/heaps/
mkdir -p include/linux/remoteproc
cp "$here/files/spu/include/linux/remoteproc/qcom_spss.h" include/linux/remoteproc/
cp "$here/files/spu/include/uapi/linux/spcom.h" \
   "$here/files/spu/include/uapi/linux/spss_utils.h" include/uapi/linux/

grep -q 'QCOM_SPSS$' drivers/remoteproc/Kconfig || sed -i '/^endmenu$/i \
config QCOM_SPSS\
\ttristate "Qualcomm Secure Processor Subsystem (SPSS) remoteproc"\
\tdepends on ARCH_QCOM && REMOTEPROC && QCOM_SCM\
' drivers/remoteproc/Kconfig
grep -q 'qcom_spss.o' drivers/remoteproc/Makefile || \
    echo 'obj-$(CONFIG_QCOM_SPSS)\t+= qcom_spss.o' >> drivers/remoteproc/Makefile

grep -q 'QCOM_GLINK_SPSS' drivers/rpmsg/Kconfig || sed -i '/^endmenu$/i \
config QCOM_GLINK_SPSS\
\ttristate "Qualcomm GLINK SPSS transport"\
\tdepends on RPMSG_QCOM_GLINK\
' drivers/rpmsg/Kconfig
grep -q 'qcom_glink_spss.o' drivers/rpmsg/Makefile || \
    echo 'obj-$(CONFIG_QCOM_GLINK_SPSS)\t+= qcom_glink_spss.o' >> drivers/rpmsg/Makefile

grep -q 'QCOM_SPCOM' drivers/soc/qcom/Kconfig || sed -i '/^endmenu$/i \
config QCOM_SPCOM\
\ttristate "Qualcomm Shared Processor Communication (SPCOM)"\
\tdepends on ARCH_QCOM\
\
config QCOM_SPSS_UTILS\
\ttristate "Qualcomm SPSS provisioning and event interface"\
\tdepends on ARCH_QCOM\
\
config QCOM_SPSS_IRQ\
\ttristate "Qualcomm SPSS secure-processor IRQ notification"\
\tdepends on ARCH_QCOM\
' drivers/soc/qcom/Kconfig
grep -q 'spcom.o' drivers/soc/qcom/Makefile || \
    echo 'obj-$(CONFIG_QCOM_SPCOM)\t+= spcom.o' >> drivers/soc/qcom/Makefile
grep -q 'spss_utils.o' drivers/soc/qcom/Makefile || \
    echo 'obj-$(CONFIG_QCOM_SPSS_UTILS)\t+= spss_utils.o' >> drivers/soc/qcom/Makefile
grep -q 'qcom_spss_irq.o' drivers/soc/qcom/Makefile || \
    echo 'obj-$(CONFIG_QCOM_SPSS_IRQ)\t+= qcom_spss_irq.o' >> drivers/soc/qcom/Makefile

# drivers/dma-buf/heaps/Kconfig is included as a fragment and has no endmenu,
# so this symbol is appended rather than inserted.
grep -q 'DMABUF_HEAPS_SP_HLOS' drivers/dma-buf/heaps/Kconfig || cat >> drivers/dma-buf/heaps/Kconfig <<'SP_HLOS_KCONFIG'

config DMABUF_HEAPS_SP_HLOS
	tristate "Qualcomm HLOS/SPSS shared DMA-BUF heap"
	depends on DMABUF_HEAPS
SP_HLOS_KCONFIG
grep -q 'qcom_sp_hlos_heap.o' drivers/dma-buf/heaps/Makefile || \
    echo 'obj-$(CONFIG_DMABUF_HEAPS_SP_HLOS)\t+= qcom_sp_hlos_heap.o' >> drivers/dma-buf/heaps/Makefile

# Kernel release tag must match the rootfs modules (vermagic ABI).
echo "-gts9wifi" > localversion-gts9wifi

# pmOS mainline base config + gts9wifi fragment.
cp "$here/files/config-mainline.aarch64" .config
scripts/kconfig/merge_config.sh -m .config "$here/files/config-gts9wifi.fragment"
unset LDFLAGS
make ARCH=arm64 LLVM=1 olddefconfig

echo ">>> kernel tree prepared: $(make ARCH=arm64 kernelrelease 2>/dev/null || true)"
