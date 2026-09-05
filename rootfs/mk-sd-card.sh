#!/bin/bash
# Assemble the bootable microSD for gts9wifi phase 1.
#
# The card replicates the pmOS SD layout the untouched eMMC boot chain
# expects: p1 ext2 /boot mounted by UUID by the pmOS initramfs, p2 ext4 root
# with the Fedora rootfs.  Your daily pmOS card is never touched — use a
# SPARE card.
#
# Usage:
#   sudo ./rootfs/mk-sd-card.sh <rootfs.tar.gz> <output.img> [size-GiB]   # image file
#   sudo ./rootfs/mk-sd-card.sh <rootfs.tar.gz> /dev/sdX                  # write to card
#
# Then: dd the image to the card (if you built a file), insert, boot.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
assets="$repo_dir/local-assets"

rootfs_tar="${1:?usage: mk-sd-card.sh <rootfs.tar.gz> <output.img|/dev/sdX> [sizeGiB]}"
target="${2:?usage: mk-sd-card.sh <rootfs.tar.gz> <output.img|/dev/sdX> [sizeGiB]}"
size_gib="${3:-12}"

# Must match the eMMC boot chain + /etc/fstab inside the rootfs tarball.
# The label matters too: with no root= in the vendor_boot cmdline, the pmOS
# initramfs finds the root partition by LABEL="pmOS_root" (verified in the
# initramfs init_functions.sh shipped on this device).
boot_uuid="b7869a36-d9a0-4403-b9fd-e0ebec016b76"
root_uuid="d2a235a8-37cd-4bac-be53-16caf2bfdd21"

boot_files="$assets/boot-files"
# Optional: the eMMC boot chain (kernel + initramfs from the bundle) never
# reads the SD /boot partition, so a fresh checkout without local assets
# just gets an empty one.
[ -d "$boot_files" ] || echo "    NOTE: no $boot_files — /boot stays empty (the eMMC chain does not use it)" >&2

cleanup() {
    [ -n "${m_boot:-}" ] && umount -f "$m_boot" 2>/dev/null || true
    [ -n "${m_root:-}" ] && umount -f "$m_root" 2>/dev/null || true
    [ -n "${loop:-}" ] && losetup -d "$loop" 2>/dev/null || true
}
trap cleanup EXIT

if [ -b "$target" ]; then
    loop="$target"
    echo ">>> partitioning $target directly"
else
    echo ">>> creating $size_gib GiB image at $target"
    truncate -s "${size_gib}G" "$target"
    loop="$(losetup --find --show "$target")"
fi

# MBR, 512 MiB boot partition, root in the rest.  A physical SD uses 512-byte
# logical sectors, so plain LBAs are fine (unlike the UFS userdata layout).
sfdisk --quiet "$loop" <<EOF
label: dos
start=8192, size=1048576, type=83
start=1056768, type=83
EOF
partprobe "$loop" 2>/dev/null || true
sleep 1

case "$loop" in
    /dev/mmcblk*|/dev/loop*) bp="${loop}p1"; rp="${loop}p2" ;;
    *) bp="${loop}1"; rp="${loop}2" ;;
esac

echo ">>> filesystems (with the UUIDs the eMMC initramfs expects)"
mkfs.ext2 -q -U "$boot_uuid" -L pmOS_boot "$bp"
mkfs.ext4 -q -U "$root_uuid" -L pmOS_root "$rp"

echo ">>> boot partition"
m_boot="$(mktemp -d)"
mount "$bp" "$m_boot"
[ -d "$boot_files" ] && cp -a "$boot_files"/. "$m_boot"/

echo ">>> root partition"
m_root="$(mktemp -d)"
mount "$rp" "$m_root"
tar xzf "$rootfs_tar" -C "$m_root"

echo ">>> injecting local assets (CI rootfs ships without them)"
kver="${GTS9_KERNEL_VERSION:-7.2.0-rc3}"
if [ -f "$assets/firmware.tar.gz" ]; then
    tar xzf "$assets/firmware.tar.gz" -C "$m_root"
else
    echo "    WARN: no firmware payload — Wi-Fi/BT/audio/sensors will be dead"
fi
if [ -d "$assets/modules/$kver" ]; then
    mkdir -p "$m_root/usr/lib/modules"
    cp -a "$assets/modules/$kver" "$m_root/usr/lib/modules/"
    depmod -b "$m_root" "$kver"
elif [ ! -d "$m_root/usr/lib/modules/$kver" ]; then
    echo "    WARN: no kernel modules for $kver (neither local assets nor the tarball) — the rootfs will not boot"
fi
if [ -f "$assets/ssh-key.pub" ]; then
    user="${GTS9_USER:-fedora}"
    install -Dm600 -o 1000 -g 1000 "$assets/ssh-key.pub" \
        "$m_root/home/$user/.ssh/authorized_keys"
else
    echo "    NOTE: no ssh key; first login uses the build user's password"
fi

echo ">>> syncing"
sync
umount "$m_boot" "$m_root"
losetup -d "$loop" 2>/dev/null || true
trap - EXIT

echo ">>> done"
if [ -b "$target" ]; then
    echo "    card written: $target — insert and boot"
else
    echo "    image ready: $target"
    echo "    write it with: sudo dd if=$target of=/dev/sdX bs=4M conv=fsync status=progress"
fi
echo "    first boot: tablet off, swap cards, power on.  SSH: ${GTS9_USER:-fedora}@172.16.42.1 (usb0)"
