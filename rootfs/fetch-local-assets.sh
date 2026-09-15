#!/bin/bash
# Populate local-assets/ with everything the CI cannot have: device firmware
# payload, kernel modules matching the flashed eMMC kernel, the known-good SD
# boot files, and your SSH public key.
#
# Requires: the tablet running pmOS attached via USB (172.16.42.1) and the
# port kit extracted at ../port-kit (see docs/PORT-KIT.md).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
assets="$repo_dir/local-assets"
port_kit="${PORT_KIT:-$(dirname "$repo_dir")/port-kit}"
device="${GTS9_DEVICE:-phablet@172.16.42.1}"
kver="${GTS9_KERNEL_VERSION:-7.2.0-rc3}"

mkdir -p "$assets/modules" "$assets/boot-files"

echo ">>> firmware payload (from port kit extraction)"
if [ -f "$port_kit/firmware-extract/firmware-samsung-gts9wifi.tar.gz" ]; then
    cp -v "$port_kit/firmware-extract/firmware-samsung-gts9wifi.tar.gz" \
        "$assets/firmware.tar.gz"
else
    echo "    missing: $port_kit/firmware-extract/firmware-samsung-gts9wifi.tar.gz" >&2
    exit 1
fi

echo ">>> Samsung WCN6855 BT firmware override (2.4GHz coexist fix)"
# The linux-firmware BT NVM/rampatch for WCN6855 mis-tunes 2.4GHz WLAN/BT
# coexistence: with Wi-Fi on, BT keyboard + audio lag.  Replacing the blobs
# with the device's own Samsung ones (as shipped on the stock /vendor) fixes
# it (docs/KNOWN-ISSUES.md #3).  Pull them from the reference device: if its
# active files differ from the stock linux-firmware backups, stage the active
# ones; otherwise this step is a no-op.
btq="$assets/firmware-overrides/usr/lib/firmware/qca"
mkdir -p "$btq"
staged=0
for f in wcnhpnv21g.bin.xz wcnhpbtfw21.tlv.xz; do
    dev=$(ssh -o BatchMode=yes "$device" \
        "md5sum /lib/firmware/qca/$f /lib/firmware/qca/$f.linuxfw.bak 2>/dev/null" || true)
    act=$(printf '%s\n' "$dev" | awk -v n="$f" '$0 ~ "  /lib/firmware/qca/"n"$" {print $1}')
    bak=$(printf '%s\n' "$dev" | awk -v n="$f" '$0 ~ "\.linuxfw\.bak$" {print $1}')
    if [ -n "$act" ] && [ -z "$bak" ]; then
        scp -q "$device:/lib/firmware/qca/$f" "$btq/$f" && staged=$((staged+1))
    elif [ -n "$act" ] && [ -n "$bak" ] && [ "$act" != "$bak" ]; then
        scp -q "$device:/lib/firmware/qca/$f" "$btq/$f" && staged=$((staged+1))
    fi
done
if [ "$staged" -eq 0 ]; then
    echo "    (device shipping stock linux-firmware BT blobs; no override staged)" >&2
    rm -rf "$assets/firmware-overrides"
else
    echo "    staged $staged Samsung BT firmware file(s) in firmware-overrides/ (device-tuned coex fix)"
fi

echo ">>> WCN6855 Wi-Fi firmware override (IOE 04866.5 mainline set + 5 GHz RX fix)"
# The linux-firmware WCN6855 amss boots but the *IOE* build
# (WLAN.HSP.1.1-04866.5-QCAHSPSWPL_V1_V2_SILICONZ_IOE-1, from CodeLinaro)
# is the reliable family on this unit; Samsung's own amss20 crashes ath11k
# (MHI_CB_EE_RDDM).  The generic linux-firmware board-2.bin leaves 5 GHz RX
# weak (KNOWN-ISSUES.md #7); the fix is to swap the matched payload for the
# LE_X13S device-tuned board file (same 0108 subsystem), which restores ~47 dB
# (docs/WIFI.md, tested 2026-09-15).  Stage the IOE amss/m3 and the fixed
# board-2.bin if they differ from the stock linux-firmware backups; else no-op.
wfx="$assets/firmware-overrides/usr/lib/firmware/ath11k/WCN6855/hw2.1"
mkdir -p "$wfx"
wfstw=0
for f in amss.bin m3.bin; do
    dev=$(ssh -o BatchMode=yes "$device" \
        "md5sum /lib/firmware/ath11k/WCN6855/hw2.1/$f /lib/firmware/ath11k/WCN6855/hw2.1/$f.linuxfw.bak 2>/dev/null" || true)
    act=$(printf '%s\n' "$dev" | awk -v n="$f" '$0 ~ "  /lib/firmware/ath11k/WCN6855/hw2.1/"n"$" {print $1}')
    bak=$(printf '%s\n' "$dev" | awk -v n="$f" '$0 ~ n"\.linuxfw\.bak$" {print $1}')
    if [ -n "$act" ] && [ -z "$bak" ]; then
        scp -q "$device:/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$wfx/$f" && wfstw=$((wfstw+1))
    elif [ -n "$act" ] && [ -n "$bak" ] && [ "$act" != "$bak" ]; then
        scp -q "$device:/lib/firmware/ath11k/WCN6855/hw2.1/$f" "$wfx/$f" && wfstw=$((wfstw+1))
    fi
done

echo ">>> WCN6855 board-2.bin override (5 GHz RX fix)"
# Generic linux-firmware board data leaves 5 GHz RX ~50 dB weak on this tablet
# (docs/KNOWN-ISSUES.md #7), even though 2.4 GHz and 5 GHz TX are healthy.  The
# fix: swap the exact-ABI matched entry
#   bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,
#   qmi-chip-id=18,qmi-board-id=255   (md5 0e92fa42…, 60,036 B generic)
# payload with the device-tuned Lenovo Snapdragon X13s board file
# (same 0108 reference subsystem; LE_X13S / NTM_TW220 payload md5 6d42746b…,
# 60,008 B) inside the board-2.bin container.  That restores 5 GHz RX to
# ~ -40 dBm (from ~ -87), verified 2026-09-15.  When the active device
# board-2.bin differs from the stock linux-firmware one, stage it; else no-op.
bdf_dev=$(ssh -o BatchMode=yes "$device" \
    "md5sum /lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin /lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin.linuxfw.bak 2>/dev/null" || true)
bdf_act=$(printf '%s\n' "$bdf_dev" | awk '$0 ~ "  /lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin$" {print $1}')
bdf_bak=$(printf '%s\n' "$bdf_dev" | awk '$0 ~ "board-2\.bin\.linuxfw\.bak$" {print $1}')
if [ -n "$bdf_act" ] && { [ -z "$bdf_bak" ] || [ "$bdf_act" != "$bdf_bak" ]; }; then
    scp -q "$device:/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin" "$wfx/board-2.bin" \
        && { echo "    staged board-2.bin ($bdf_act) carrying the 5 GHz RX fix"; wfstw=$((wfstw+1)); }
fi
if [ "$wfstw" -eq 0 ]; then
    echo "    (device shipping stock linux-firmware WCN6855 set; no override staged)" >&2
    rmdir -p "$wfx" 2>/dev/null || true
    [ -d "$assets/firmware-overrides" ] || rm -rf "$assets/firmware-overrides"
else
    echo "    staged IOE 04866.5 amss/m3 + 5 GHz-fixed board-2.bin in firmware-overrides/ (reliable mainline Wi-Fi set)"
fi

echo ">>> known-good SD boot files (from port kit)"
cp -av "$port_kit/known-good-sd-boot/." "$assets/boot-files/"

echo ">>> kernel modules for $kver (from device: $device)"
ssh -o BatchMode=yes "$device" "test -d /usr/lib/modules/$kver" \
    || { echo "    device does not have $kver modules" >&2; exit 1; }
rsync -a --delete "$device:/usr/lib/modules/$kver/" "$assets/modules/$kver/"

echo ">>> SSH public key"
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    cp -v "$HOME/.ssh/id_ed25519.pub" "$assets/ssh-key.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    cp -v "$HOME/.ssh/id_rsa.pub" "$assets/ssh-key.pub"
else
    echo "    no public key found in ~/.ssh (first boot will need the password)" >&2
fi

echo ">>> local-assets/ ready:"
du -sh "$assets"/* | sed 's/^/    /'
