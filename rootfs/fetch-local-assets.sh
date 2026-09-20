#!/bin/bash
# Populate local-assets/ with everything the CI cannot have: device firmware
# payload, kernel modules matching the flashed eMMC kernel, the known-good SD
# boot files, and your SSH public key.
#
# Requires: the tablet running pmOS attached via USB (172.16.42.1) and the
# port kit extracted at ../port-kit (see the gts9wifi Fedora port kit page in the wiki).
#
# Note: the device-independent overrides staged below (Cirrus CS35L45, the VPU
# blob, the IOE Wi-Fi set and the 5 GHz BDF) are also staged at build time by
# rootfs/stage-public-firmware.sh, which is what CI uses because it needs no
# tablet.  The copies here exist so local-assets/ can be pre-staged for a
# fully offline build; a URL or checksum change belongs in both.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
assets="$repo_dir/local-assets"
port_kit="${PORT_KIT:-$(dirname "$repo_dir")/port-kit}"
device="${GTS9_DEVICE:-phablet@172.16.42.1}"
kver="${GTS9_KERNEL_VERSION:-7.2.6}"

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
# it (the known-issues page in the wiki, issue 3).  Pull them from the reference device: if its
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
# weak (the known-issues page in the wiki, issue 7); the fix is to swap the
# matched payload for the LE_X13S device-tuned board file (same 0108
# subsystem), which restores ~47 dB (the Wi-Fi page in the wiki, tested
# 2026-09-15).  Stage the IOE amss/m3 and the fixed board-2.bin if they differ
# from the stock linux-firmware backups; else no-op.
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
# (the known-issues page in the wiki, issue 7), even though 2.4 GHz and 5 GHz TX are healthy.  The
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

echo ">>> Cirrus CS35L45 speaker-protection firmware (issue 17)"
# Mainline's wm_adsp loads cirrus/<part>-dsp1-spk-prot.{wmfw,bin} for the
# CS35L45's speaker-protection DSP (cs35l45.c sets dsp->fw =
# WM_ADSP_FW_SPK_PROT).  linux-firmware ships no cs35l45 blobs at all, so
# without these the DSP stays empty and nothing bounds cone excursion in
# hardware -- which is why the UCM used to hold the per-amp volume ~19 dB
# below full scale.
#
# The UCM now sets 428 (-7.25 dB) *on the assumption that this protection is
# present*, so a failure here is fatal rather than a warning: raising the
# volume without the limiter is the one combination that can damage the
# speakers.
#
# Deliberately NOT staged: cs35l45-dsp1-spk-prot-calib.bin, which the same
# public payload also carries.  It is a separate deploy group -- the .bin
# above declares deploy_group "left" (tuning) and this one "left_cal"
# (SPKChar speaker characterisation) -- and mainline's
# wm_adsp_request_firmware_files() requests exactly one .wmfw and one .bin,
# so nothing would ever load it.  Staging it would imply protection we do not
# have: CAL_R and CAL_STATUS read 0 on the tablet.
cirrus="$assets/firmware-overrides/usr/lib/firmware/cirrus"
mkdir -p "$cirrus"
cfw_base="${GTS9_CIRRUS_BASE:-https://raw.githubusercontent.com/Azkali/gts9wifi-firmware/main/cirrus}"
for spec in \
    "cs35l45-dsp1-spk-prot.wmfw:214ae6e1de113fde4f2568cdcd08bd0bf171d5b732a9eb44cfb4a8f6d9a67043" \
    "cs35l45-dsp1-spk-prot.bin:5fd06ccbd3c8a071121609f642956f16754851814aa2fb4133e4becc2799e79f"; do
    f="${spec%%:*}"; want="${spec##*:}"
    if ! curl -fsSL --max-time 60 -o "$cirrus/$f" "$cfw_base/$f"; then
        echo "    FAILED to download $f from $cfw_base" >&2
        echo "    The UCM sets the per-amp volume to 428 assuming this firmware is" >&2
        echo "    present; shipping without it risks the speakers.  Put the file in" >&2
        echo "    $cirrus/ and re-run (GTS9_CIRRUS_BASE overrides the source)." >&2
        exit 1
    fi
    got="$(sha256sum "$cirrus/$f" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        echo "    FAILED checksum for $f: got $got want $want" >&2
        exit 1
    fi
done
echo "    staged 2 Cirrus CS35L45 speaker-protection file(s) in firmware-overrides/ (issue 17)"

# VPU / iris video-decoder firmware (issue 16).  The driver asks for exactly
# this name -- the DT's &iris firmware-name -- and fails with ENOENT without
# it, so /dev/video17 and /dev/video18 register but every decode attempt logs
# "Direct firmware load for qcom/vpu/vpu30_4v.mbn failed with error -2" and the
# VPU never boots.  linux-firmware ships a whole family of vpu30_*_s* blobs but
# not this one, and the CI firmware payload does not carry it either, so the
# public copy is the only route that avoids unpacking the super partition with
# lpunpack.  It is Samsung's signed image, which is what this device's
# TrustZone accepts (the blob is PAS-authenticated, so a generic one is no use).
#
# Fatal on failure, like the Cirrus block above: without it the port silently
# falls back to software decode, which is the class of quiet regression this
# port keeps hitting (the inert tmpfiles entries, the dropped file
# capabilities).  The blob is proprietary, so it cannot be committed.
vpu="$assets/firmware-overrides/usr/lib/firmware/qcom/vpu"
mkdir -p "$vpu"
vpu_base="${GTS9_VPU_BASE:-https://raw.githubusercontent.com/Azkali/gts9wifi-firmware/main/qcom/sm8550/gts9wifi}"
for spec in \
    "vpu30_4v.mbn:431e976f95e3306ad9473e88c1c83795fce8de5811a4c7203c27e498f8aa3787"; do
    f="${spec%%:*}"; want="${spec##*:}"
    if ! curl -fsSL --max-time 120 -o "$vpu/$f" "$vpu_base/$f"; then
        echo "    FAILED to download $f from $vpu_base" >&2
        echo "    The iris decoder needs it at /lib/firmware/qcom/vpu/$f, or video" >&2
        echo "    decode silently falls back to software.  Put the file in" >&2
        echo "    $vpu/ and re-run (GTS9_VPU_BASE overrides the source)." >&2
        exit 1
    fi
    got="$(sha256sum "$vpu/$f" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        echo "    FAILED checksum for $f: got $got want $want" >&2
        exit 1
    fi
done
echo "    staged 1 VPU/iris video-decoder firmware file in firmware-overrides/ (issue 16)"

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
