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
