#!/bin/bash
# Install the gts9wifi Fedora rootfs into the tablet's INTERNAL storage
# (userdata partition), replacing the microSD as the root device.
#
# *** THIS DESTROYS ANDROID'S USERDATA ***
# The stock f2fs userdata partition is reformatted as one ext4.  Photos,
# app data, everything on the tablet is gone.  Android stays restorable
# via TWRP "Format Data" or a full Odin firmware flash; the boot-chain
# partitions and recovery are never touched here.  The script therefore
# requires explicit interactive confirmation before formatting and will
# not proceed in any non-interactive context.
#
# The boot chain never changes: the flashed bundle's cmdline finds root by
# UUID, and this script formats userdata with that exact UUID
# (d2a235a8-37cd-4bac-be53-16caf2bfdd21), so an already-flashed TWRP zip
# keeps working as-is.  A microSD prepared by mk-sd-card.sh carries the
# same UUID and stays a bootable rescue card - but never boot with both
# inserted (the root lookup is by UUID and becomes ambiguous).
#
# Runs from the build PC against a tablet sitting in TWRP recovery:
#   ./rootfs/mk-internal-storage.sh <path-to>/gts9wifi-fedora-44-rootfs.tar.gz
#
# What it does on the device (all via adb, nothing manual in TWRP's UI):
#   0. verifies recovery mode, the device codename and the model
#   1. unmounts TWRP's automatic /data + /sdcard mounts of userdata
#   2. checks the partition size before doing anything destructive
#   3. mke2fs the full partition (~105 GB) as ext4 with the cmdline UUID
#   4. pushes + extracts the rootfs tarball, then the optional
#      local-assets extras mk-sd-card.sh also injects (firmware payload,
#      kernel modules, ssh key - the release tarball already carries all
#      three)
#   5. rewrites the fstab root-only (see below), creates the mountpoint
#      dirs, e2fsck, done - reboot to system WITHOUT the microSD inserted
#
# The fstab rewrite is the Fedora-specific step: the tarball's fstab
# mounts /boot by the SD card's ext2 boot UUID, and there is no such
# partition on internal storage.  systemd would sit 90 s waiting for the
# missing device and then drop the boot to emergency mode.
#
# Never touches any partition other than userdata.  Does not reboot.

set -euo pipefail

rootfs_tar="${1:?usage: mk-internal-storage.sh <rootfs.tar.gz> (tablet must be in TWRP)}"
[ -f "$rootfs_tar" ] || { echo "no such tarball: $rootfs_tar" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
assets="$repo_dir/local-assets"
kver="${GTS9_KERNEL_VERSION:-7.2.6}"
user="${GTS9_USER:-fedora}"

# Must match boot/cmdline.txt (root=UUID=...) and the fstab written by
# build-rootfs.sh.  One UUID, three places, zero bundle reflashes.
root_uuid="d2a235a8-37cd-4bac-be53-16caf2bfdd21"

command -v adb >/dev/null || { echo "adb not installed" >&2; exit 1; }

state="$(adb get-state 2>/dev/null || true)"
[ "$state" = "recovery" ] || {
    echo "device not in recovery (adb get-state: '${state:-none}')" >&2
    echo "boot TWRP (Volume Up + Power past the Samsung logo) and retry" >&2
    exit 1
}

device="$(adb shell getprop ro.product.device | tr -d '\r')"
em_model="$(adb shell getprop ro.boot.em.model | tr -d '\r')"
echo ">>> TWRP connected: device=$device model=${em_model:-unknown}"

case "$device" in
    gts9|gts9wifi) ;;
    *) echo "REFUSING: expected device gts9/gts9wifi, got '$device'" >&2; exit 1 ;;
esac
if [ -n "$em_model" ] && [ "$em_model" != "SM-X710" ]; then
    echo "REFUSING: expected model SM-X710, got '$em_model'" >&2; exit 1
fi

# Resolve the partition by its partition label and sanity-check its size
# BEFORE any destructive step.
part_path="$(adb shell 'ls /dev/block/by-name/userdata 2>/dev/null' | tr -d '\r')"
[ -n "$part_path" ] || { echo "REFUSING: userdata partition not found by label" >&2; exit 1; }
part_size="$(adb shell "blockdev --getsize64 $part_path" | tr -d '\r')"
[ "$part_size" -gt $((100 * 1024 * 1024 * 1024)) ] 2>/dev/null || {
    echo "REFUSING: userdata is only ${part_size:-?} bytes - wrong partition?" >&2; exit 1; }

cat >&2 <<EOF

****************************************************************************
*                                                                          *
*   WARNING: about to FORMAT THE TABLET'S INTERNAL USERDATA (~$((part_size / 1024 / 1024 / 1024)) GB)
*                                                                          *
*   Android's data (apps, photos, settings - everything) will be           *
*   PERMANENTLY DESTROYED and replaced with the Fedora rootfs.             *
*   Target: $part_path
*                                                                          *
*   Restore path afterwards: TWRP Format Data, or a full Odin flash.       *
*                                                                          *
****************************************************************************
EOF
if [ ! -t 0 ]; then
    echo "REFUSING: no interactive terminal for confirmation (re-run from a TTY)" >&2
    exit 1
fi
read -r -p "Type DESTROY to format userdata and install Fedora: " answer
[ "$answer" = "DESTROY" ] || { echo "aborted - nothing was modified" >&2; exit 1; }

echo ">>> pushing the rootfs tarball (this takes a few minutes)"
adb push "$rootfs_tar" /tmp/gts9-rootfs.tar.gz

# The optional injections mk-sd-card.sh does on the PC side, applied here
# on the tablet instead.  Everything is pushed as a file and extracted in
# the device shell below - no depmod needed there, the RPM-built and
# rsynced-from-device module trees both ship their prebuilt modules.dep.
extras="$(mktemp -d)"
trap 'rm -rf "$extras"' EXIT
if [ -f "$assets/firmware.tar.gz" ]; then
    echo ">>> firmware payload from local-assets"
    adb push "$assets/firmware.tar.gz" /tmp/gts9-firmware.tar.gz
else
    echo "    NOTE: no firmware payload in local-assets (the release tarball carries its own)" >&2
fi
if [ -d "$assets/modules/$kver" ]; then
    echo ">>> kernel modules from local-assets"
    tar -C "$assets/modules" -czf "$extras/modules.tar.gz" "$kver"
    adb push "$extras/modules.tar.gz" /tmp/gts9-modules.tar.gz
fi
if [ -f "$assets/ssh-key.pub" ]; then
    echo ">>> ssh key from local-assets"
    adb push "$assets/ssh-key.pub" /tmp/gts9-ssh-key.pub
else
    echo "    NOTE: no ssh key in local-assets; first login uses the build user's password" >&2
fi

# Everything runs in one shell: a failure leaves the target either
# untouched (pre-mke2fs) or freshly formatted (post-mke2fs; the script is
# idempotent from the mke2fs step on - rerun it).
adb shell '
set -e
DEV=/dev/block/by-name/userdata
[ -b "$DEV" ] || { echo "no userdata partition" >&2; exit 1; }
size=$(blockdev --getsize64 "$DEV")
[ "$size" -gt $((100 * 1024 * 1024 * 1024)) ] || {
    echo "userdata is only $size bytes - refusing (wrong partition?)" >&2; exit 1; }
# TWRP auto-mounts userdata; mke2fs refuses to run on a mounted device.
umount /sdcard 2>/dev/null || true
umount /data 2>/dev/null || true
mke2fs -F -t ext4 -m 1 -U '"$root_uuid"' -L pmOS_root "$DEV"
mkdir -p /rmnt
mount -t ext4 "$DEV" /rmnt
tar xzf /tmp/gts9-rootfs.tar.gz -C /rmnt
if [ -f /tmp/gts9-firmware.tar.gz ]; then
    tar xzf /tmp/gts9-firmware.tar.gz -C /rmnt
fi
if [ -f /tmp/gts9-modules.tar.gz ]; then
    mkdir -p /rmnt/usr/lib/modules
    tar xzf /tmp/gts9-modules.tar.gz -C /rmnt/usr/lib/modules
fi
# Root-only fstab: the tarball one mounts /boot by the SD ext2 UUID, and
# no such partition exists here (90 s device timeout, then emergency mode).
printf "UUID='"$root_uuid"' /     ext4 defaults 0 0\n" > /rmnt/etc/fstab
if [ ! -d /rmnt/usr/lib/modules/'"$kver"'-gts9wifi ] && [ ! -d /rmnt/usr/lib/modules/'"$kver"' ]; then
    echo "WARN: no kernel modules in the installed root - it will not boot." >&2
    echo "      Use the release tarball, or local-assets/modules/'"$kver"' before rerunning." >&2
fi
if [ -f /tmp/gts9-ssh-key.pub ]; then
    mkdir -p /rmnt/home/'"$user"'/.ssh
    cp /tmp/gts9-ssh-key.pub /rmnt/home/'"$user"'/.ssh/authorized_keys
    chown -R 1000:1000 /rmnt/home/'"$user"'/.ssh
    chmod 700 /rmnt/home/'"$user"'/.ssh
    chmod 600 /rmnt/home/'"$user"'/.ssh/authorized_keys
fi
mkdir -p /rmnt/proc /rmnt/sys /rmnt/dev /rmnt/run /rmnt/tmp /rmnt/boot \
         /rmnt/mnt/vendor/persist /rmnt/vendor/dsp /rmnt/vendor/firmware_mnt
chmod 1777 /rmnt/tmp
rm -f /tmp/gts9-rootfs.tar.gz /tmp/gts9-firmware.tar.gz \
      /tmp/gts9-modules.tar.gz /tmp/gts9-ssh-key.pub
sync
umount /rmnt
e2fsck -fy "$DEV"
echo ">>> userdata install complete"
'

echo ">>> done. Now:"
echo "    1. physically REMOVE the microSD (same root UUID - keep exactly one)"
echo "    2. TWRP -> Reboot -> System"
echo "    3. ssh ${user}@172.16.42.1  (usb0)"
