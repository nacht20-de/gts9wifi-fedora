#!/bin/bash
# Stage the device-independent firmware overrides into a rootfs tree.
#
#   rootfs/stage-public-firmware.sh <rootfs-dir>
#
# Why this exists: rootfs/fetch-local-assets.sh needs a running tablet, so CI
# can never run it.  Because of that, every image built there shipped
# linux-firmware's generic blobs and silently lost three fixes the port is
# documented as having -- the CS35L45 speaker protection (issue 17), the iris
# VPU firmware (issue 16) and the validated WCN6855 Wi-Fi set with the 5 GHz RX
# BDF (issue 7).  Everything staged here is either relocated out of the
# firmware payload or downloaded from a pinned public URL and checksum-verified,
# so it needs no device and no local-assets/.
#
# It is idempotent and a no-op over a tree that is already correct, so a local
# build that ran fetch-local-assets.sh keeps the device-fetched files (same
# checksums) and skips every download.
#
# Env:
#   GTS9_SKIP_PUBLIC_FIRMWARE=1  report what is missing instead of downloading
#   GTS9_CIRRUS_BASE             cirrus/ source (default: the Azkali firmware repo)
#   GTS9_VPU_BASE                qcom/vpu/ source (default: the Azkali firmware repo)
#   GTS9_IOE_BASE                WCN6855 IOE source (default: CodeLinaro ath11k-firmware)
#   GTS9_BDF_REF_URL             board-2.bin reference container (default: CodeLinaro)

set -euo pipefail

rootfs="${1:-}"
if [ -z "$rootfs" ] || [ ! -d "$rootfs" ]; then
    echo "usage: $(basename "$0") <rootfs-dir>" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
bdftool="$script_dir/../tools/bdftool.py"
fw="$rootfs/usr/lib/firmware"
skip="${GTS9_SKIP_PUBLIC_FIRMWARE:-0}"
missing=()

# fetch <url> <dest> <sha256> <label>
# Leaves an already-correct file alone; otherwise downloads and verifies it.
fetch() {
    local url="$1" dest="$2" want="$3" label="$4" got
    got="$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
        return 0
    fi
    if [ "$skip" = 1 ]; then
        missing+=("$label")
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    if ! curl -fsSL --max-time 300 -o "$dest" "$url"; then
        echo "    FAILED to download $label" >&2
        echo "      from $url" >&2
        missing+=("$label")
        return 1
    fi
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        echo "    FAILED checksum for $label: got $got want $want" >&2
        rm -f "$dest"
        missing+=("$label")
        return 1
    fi
    echo "    staged $label"
}

echo ">>> CS35L45 speaker-protection firmware (issue 17)"
# Mainline's wm_adsp requests cirrus/<part>-dsp1-spk-prot.{wmfw,bin} (cs35l45.c
# sets dsp->fw = WM_ADSP_FW_SPK_PROT).  The firmware payload carries both files
# but at the firmware root, where nothing looks for them, so relocate them.
#
# The payload's cs35l45-dsp1-spk-prot-calib.bin is deliberately left where it
# is: it is a separate deploy group (left_cal, SPKChar speaker
# characterisation) that wm_adsp never requests -- it asks for exactly one
# .wmfw and one .bin -- and staging it would imply speaker characterisation
# this unit does not have (CAL_R/CAL_STATUS read 0).
mkdir -p "$fw/cirrus"
for f in cs35l45-dsp1-spk-prot.wmfw cs35l45-dsp1-spk-prot.bin; do
    if [ -f "$fw/$f" ] && [ ! -f "$fw/cirrus/$f" ]; then
        mv "$fw/$f" "$fw/cirrus/$f"
    fi
done
cirrus_base="${GTS9_CIRRUS_BASE:-https://raw.githubusercontent.com/Azkali/gts9wifi-firmware/main/cirrus}"
fetch "$cirrus_base/cs35l45-dsp1-spk-prot.wmfw" "$fw/cirrus/cs35l45-dsp1-spk-prot.wmfw" \
    214ae6e1de113fde4f2568cdcd08bd0bf171d5b732a9eb44cfb4a8f6d9a67043 \
    "CS35L45 speaker protection (cs35l45-dsp1-spk-prot.wmfw)" || true
fetch "$cirrus_base/cs35l45-dsp1-spk-prot.bin" "$fw/cirrus/cs35l45-dsp1-spk-prot.bin" \
    5fd06ccbd3c8a071121609f642956f16754851814aa2fb4133e4becc2799e79f \
    "CS35L45 speaker protection (cs35l45-dsp1-spk-prot.bin)" || true

echo ">>> iris VPU / video-decoder firmware (issue 16)"
# The driver asks for exactly the name in the DTS (&iris firmware-name) and
# fails with ENOENT without it: /dev/video17 registers but every decode logs
# "Direct firmware load for qcom/vpu/vpu30_4v.mbn failed with error -2" and the
# VPU never boots.  linux-firmware ships a family of vpu30_*_s* blobs but not
# this one, and the CI payload does not carry it either.  It is Samsung's
# signed image, which is what this device's TrustZone accepts -- the blob is
# PAS-authenticated, so a generic one is no use -- and being proprietary it
# cannot be committed to the repo.
vpu_base="${GTS9_VPU_BASE:-https://raw.githubusercontent.com/Azkali/gts9wifi-firmware/main/qcom/sm8550/gts9wifi}"
fetch "$vpu_base/vpu30_4v.mbn" "$fw/qcom/vpu/vpu30_4v.mbn" \
    431e976f95e3306ad9473e88c1c83795fce8de5811a4c7203c27e498f8aa3787 \
    "iris VPU firmware (qcom/vpu/vpu30_4v.mbn)" || true

echo ">>> WCN6855 Wi-Fi firmware: the IOE 04866.5 mainline set (issue 7)"
# The linux-firmware WCN6855 amss boots but the *IOE* build
# (WLAN.HSP.1.1-04866.5-QCAHSPSWPL_V1_V2_SILICONZ_IOE-1) is the reliable family
# on this unit; Samsung's own non-LITE amss20 crashes ath11k with
# MHI_CB_EE_RDDM.  CodeLinaro mirrors Qualcomm's ath11k-firmware tree, where
# the IOE build lives under "hw2.0@nfa765" while linux-firmware names the same
# directory hw2.1 -- the destination below is what the kernel loads.
ioe_base="${GTS9_IOE_BASE:-https://raw.githubusercontent.com/CodeLinaro-mirror/ath-firmware_ath11k-firmware/main/WCN6855/hw2.0@nfa765/1.1/WLAN.HSP.1.1-04866.5-QCAHSPSWPL_V1_V2_SILICONZ_IOE-1}"
fetch "$ioe_base/amss.bin" "$fw/ath11k/WCN6855/hw2.1/amss.bin" \
    8cb5e63877c7cfdc5002a7d28bc5d7f7d20368183e6f93b12c977bfd0351c7b7 \
    "WCN6855 IOE 04866.5 amss.bin" || true
fetch "$ioe_base/m3.bin" "$fw/ath11k/WCN6855/hw2.1/m3.bin" \
    d20460e104b85a7be9cdb5199c4d8b94a9787912e3f920acd845694d4d71f730 \
    "WCN6855 IOE 04866.5 m3.bin" || true

echo ">>> WCN6855 board data: 5 GHz RX fix (issue 7)"
# The container linux-firmware ships picks, for this tablet's exact-ABI slot
#   bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,
#   qmi-chip-id=18,qmi-board-id=255
# Qualcomm's generic reference payload, which leaves 5 GHz RX ~47 dB weak
# (-87 dBm vs -40 dBm at 2-3 m; 2.4 GHz unaffected).  The *same* container
# already carries the device-tuned Lenovo Snapdragon X13s payload as a variant
# entry (variant=NTM_TW220, same board-id) -- but ath11k only consults variant
# entries when the DT or ACPI declares one, and this port's DTS declares none,
# which is exactly why the generic payload always wins.  So swap the tuned
# payload into the exact-ABI slot; the rest of the container stays byte-for-byte
# identical.
bdf="$fw/ath11k/WCN6855/hw2.1/board-2.bin"
# Fedora's atheros-firmware ships the container xz-compressed (board-2.bin.xz),
# and the kernel tries the plain name before the .xz, so an uncompressed copy
# overrides it.  The firmware payload normally provides one; decompress the
# packaged copy when it did not, so the fix does not depend on the payload.
if [ ! -f "$bdf" ] && [ -f "$bdf.xz" ] && command -v xz >/dev/null 2>&1; then
    xz -dc "$bdf.xz" > "$bdf"
fi
slot="bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,qmi-chip-id=18,qmi-board-id=255"
generic_md5="0e92fa42e6b9895e4afd7a281bbed079"      # Qualcomm reference, weak 5 GHz RX
tuned_md5="6d42746b861fc52380a19dfdfaa702f1"        # X13s / NTM_TW220, device-tuned
tuned_sha="77b1b9ef636ce8492723aa7c2ff2c42c2e5e81a43967d7f32bfdef93a31bf8c4"
bdf_ref_url="${GTS9_BDF_REF_URL:-https://raw.githubusercontent.com/CodeLinaro-mirror/ath-firmware_ath11k-firmware/main/WCN6855/hw2.0/board-2.bin}"
bdf_ref_sha="9287fa8d14d915892666b03e9403135875d08371fd1438d2c6d9fe96ae71cf68"

if [ ! -f "$bdf" ]; then
    missing+=("WCN6855 board-2.bin (5 GHz RX fix, issue 7)")
elif [ ! -f "$bdftool" ]; then
    echo "    FAILED: $bdftool not found (needed to edit the board-2.bin container)" >&2
    missing+=("WCN6855 board-2.bin (5 GHz RX fix, issue 7)")
elif ! command -v python3 >/dev/null 2>&1; then
    echo "    FAILED: python3 not found (needed to edit the board-2.bin container)" >&2
    missing+=("WCN6855 board-2.bin (5 GHz RX fix, issue 7)")
else
    slot_md5="$(python3 "$bdftool" md5s "$bdf" | awk -v n="$slot" '$3 == n {print $2}')"
    if [ "$slot_md5" = "$tuned_md5" ]; then
        echo "    board-2.bin already carries the tuned payload in the exact-ABI slot"
    elif [ "$slot_md5" != "$generic_md5" ]; then
        echo "    FAILED: exact-ABI slot not recognised (payload md5 ${slot_md5:-none})" >&2
        missing+=("WCN6855 board-2.bin (5 GHz RX fix, issue 7): unrecognised container")
    else
        tmp="$(mktemp -d)"
        tuned="$tmp/tuned.bin"
        python3 "$bdftool" dump "$bdf" "$slot,variant=NTM_TW220" "$tuned" >/dev/null 2>&1 || true
        if [ "$(sha256sum "$tuned" 2>/dev/null | cut -d' ' -f1)" != "$tuned_sha" ]; then
            # Not in this container: take it from the pinned reference container.
            ref="$tmp/ref.bin"
            if fetch "$bdf_ref_url" "$ref" "$bdf_ref_sha" \
                    "WCN6855 reference board-2.bin (BDF source)"; then
                rm -f "$tuned"
                python3 "$bdftool" dump "$ref" "$slot,variant=NTM_TW220" "$tuned" \
                    >/dev/null 2>&1 || true
            fi
        fi
        if [ "$(sha256sum "$tuned" 2>/dev/null | cut -d' ' -f1)" != "$tuned_sha" ]; then
            echo "    FAILED: the device-tuned payload could not be obtained" >&2
            missing+=("WCN6855 board-2.bin (5 GHz RX fix, issue 7): no tuned payload")
        else
            python3 "$bdftool" swap "$bdf" "$tmp/fixed.bin" "$slot" "$tuned" >/dev/null
            mv "$tmp/fixed.bin" "$bdf"
            echo "    board-2.bin: tuned payload ($tuned_md5) swapped into the exact-ABI slot"
        fi
        rm -rf "$tmp"
    fi
fi

if [ "${#missing[@]}" -gt 0 ]; then
    if [ "$skip" = 1 ]; then
        echo "" >&2
        echo ">>> GTS9_SKIP_PUBLIC_FIRMWARE=1: not staged.  The image will lose the" >&2
        echo ">>> fixes these carry -- software video decode, weak 5 GHz RX, and no" >&2
        echo ">>> CS35L45 speaker protection while the UCM sets the per-amp volume to" >&2
        echo ">>> 428 (-7.25 dB):" >&2
        for m in "${missing[@]}"; do echo "    - $m" >&2; done
    else
        echo "" >&2
        echo ">>> FATAL: required firmware could not be staged:" >&2
        for m in "${missing[@]}"; do echo "    - $m" >&2; done
        echo ">>> Shipping without it is a silent regression, or -- for the CS35L45" >&2
        echo ">>> pair -- a speaker hazard.  Re-run with network access, or set" >&2
        echo ">>> GTS9_SKIP_PUBLIC_FIRMWARE=1 to build anyway." >&2
        exit 1
    fi
fi

echo ">>> Public firmware overrides staged under $fw"
