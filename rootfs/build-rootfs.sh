#!/bin/bash
# Build a Fedora aarch64 rootfs for the Samsung Galaxy Tab S9 Wi-Fi (gts9wifi).
#
# MUST run inside an aarch64 Fedora environment — either the GitHub Actions
# arm64 runner container (see .github/workflows/rootfs.yml) or locally:
#
#   podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
#       ./rootfs/build-rootfs.sh
#
# Everything is native arm64: no qemu, no cross toolchain.
#
# Default image = the release layout: Fedora Workstation (GNOME + gdm),
# user 'fedora' (password 'fedora'), the full device stack, the firmware
# payload and the pinned kernel RPM baked in — flash the matching TWRP
# bundle, write the SD, boot to the gdm login.  GTS9_DESKTOP=core builds
# the small headless debug image instead.
#
# Boot: the eMMC boot chain (boot/init_boot/vendor_boot/dtbo from this
# repo's bundle) loads the kernel + dracut initramfs, which mounts the SD
# root by the root=UUID on the vendor_boot cmdline.

set -euo pipefail

fedora_release="${FEDORA_RELEASE:-44}"
kver="${GTS9_KERNEL_VERSION:-7.2.0-rc3}"
build_user="${GTS9_USER:-fedora}"
# gnome = Fedora Workstation environment + gdm (the release image);
# core = headless @core only (smaller bring-up/debug image).
desktop="${GTS9_DESKTOP:-gnome}"
# CI passes a downloaded, sha256-verified firmware payload and the pinned
# kernel RPM here so the release image is self-contained: firmware blobs and
# a module tree matching the boot bundle live inside the rootfs.
firmware_tar="${FIRMWARE_TARBALL:-}"
kernel_rpm="${KERNEL_RPM:-}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"
rootfs="${ROOTFS_DIR:-$repo_dir/out/rootfs}"
outdir="${OUT_DIR:-$repo_dir/out}"
assets="$repo_dir/local-assets"

# Fallback for local runs: the fetched payload in local-assets.
[ -n "$firmware_tar" ] || firmware_tar="$assets/firmware.tar.gz"

# The partition UUIDs the untouched pmOS initramfs/eMMC boot chain expects
# (see docs/PORT-KIT.md: the initramfs mounts /boot by this UUID).
boot_uuid="b7869a36-d9a0-4403-b9fd-e0ebec016b76"
root_uuid="d2a235a8-37cd-4bac-be53-16caf2bfdd21"

missing_assets=()

echo ">>> Fedora $fedora_release rootfs for gts9wifi, kernel $kver"
mkdir -p "$rootfs" "$outdir"

echo ">>> Installing rootfs packages"
# --use-host-config: dnf5 loads repositories from the (empty) installroot
# otherwise; the container's own repo config + gpg keys are what we want.
dnf -y --installroot="$rootfs" --releasever="$fedora_release" \
    --use-host-config --setopt=install_weak_deps=False --setopt=tsflags=nodocs install \
    @core \
    NetworkManager NetworkManager-wifi wpa_supplicant \
    openssh-server openssh-clients \
    sudo chrony zram-generator python3 \
    bluez bluez-tools \
    qrtr \
    alsa-ucm alsa-utils dtc \
    libqmi libqrtr-glib protobuf-c libmbim \
    systemd-pam \
    atheros-firmware qcom-firmware \
    e2fsprogs kmod

if [ "$desktop" = "gnome" ]; then
    echo ">>> Installing the GNOME Workstation environment"
    # Same environment group the Fedora Workstation install uses; gdm,
    # pipewire, gnome-shell and the Wayland session come with it.  GNOME's
    # touch support (on-screen keyboard, gestures) needs no extra setup.
    dnf -y --installroot="$rootfs" --releasever="$fedora_release" \
        --use-host-config --setopt=install_weak_deps=False --setopt=tsflags=nodocs install \
        '@^workstation-product-environment'
    # The first-login welcome wizard has nothing to offer in a pre-provisioned
    # image; drop it so the first boot goes straight to the gdm login.
    dnf -y --installroot="$rootfs" --use-host-config -q remove \
        gnome-initial-setup || true
    # The workstation group pulls the linux-firmware meta as mandatory; this
    # board needs none of it (the device payload plus atheros/qcom cover
    # every consumer), and it is half a gigabyte of dead weight.
    dnf -y --installroot="$rootfs" --use-host-config -q remove \
        linux-firmware amd-gpu-firmware intel-gpu-firmware nvidia-gpu-firmware \
        iwlwifi-dvm-firmware iwlwifi-mld-firmware iwlwifi-mvm-firmware \
        iwlegacy-firmware mt7xxx-firmware realtek-firmware tiwilink-firmware \
        libertas-firmware brcmfmac-firmware nxpwireless-firmware \
        qcom-wwan-firmware || true
    dnf -y --installroot="$rootfs" --use-host-config --setopt=tsflags=nodocs \
        install atheros-firmware qcom-firmware || true
fi

echo ">>> Installing native build dependencies (build container only)"
# systemd: the base container image ships without it, but systemctl --root=
# below needs the binary.
dnf -y -q install systemd meson ninja-build gcc git curl tar patch make \
    "pkgconf-pkg-config" \
    glib2-devel libgudev-devel systemd-devel polkit-devel kmod \
    libqmi-devel protobuf-c-devel qrtr-devel xz-devel \
    python3-devel python3-protobuf

echo ">>> Building libssc 0.4.4 (not in Fedora)"
# Same source the pmOS port uses; provides libssc.so + ssccli.
sscdir="$(mktemp -d)"
curl -sfL "https://codeberg.org/DylanVanAssche/libssc/archive/v0.4.4.tar.gz" \
    | tar xz -C "$sscdir" --strip-components=1
meson setup "$sscdir/build" "$sscdir" -Dprefix=/usr -Db_lto=true
meson compile -C "$sscdir/build"
DESTDIR="$sscdir/staging" meson install --no-rebuild -C "$sscdir/build"
cp -a "$sscdir/staging/." "$rootfs/"
# Let the iio-sensor-proxy build below find the staged libssc.
export PKG_CONFIG_PATH="$sscdir/staging/usr/lib64/pkgconfig:$sscdir/staging/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo ">>> Building pd-mapper 1.1 (not in Fedora)"
# Binary only: the sm8550 ADSP boots without service-registry JSONs (verified
# on the pmOS device).  Ships its own systemd unit.
pdmdir="$(mktemp -d)"
curl -sfL "https://github.com/andersson/pd-mapper/archive/refs/tags/v1.1.tar.gz" \
    | tar xz -C "$pdmdir" --strip-components=1
make -C "$pdmdir" -j"$(nproc)" prefix=/usr
make -C "$pdmdir" install prefix=/usr DESTDIR="$pdmdir/staging"
cp -a "$pdmdir/staging/." "$rootfs/"

echo ">>> Building hexagonrpcd 0.4.0 with Samsung patches"
# Upstream tag + the two Samsung patches from the pmOS port (large FastRPC
# inbufs; Samsung sensor-registry writes) + Alpine's systemd-units patch.
hexdir="$(mktemp -d)"
git clone -q --depth 1 --branch v0.4.0 https://github.com/linux-msm/hexagonrpc "$hexdir/src"
for p in "$repo_dir"/specs/hexagonrpcd-samsung/patches/*.patch; do
    patch -d "$hexdir/src" -p1 < "$p"
done
meson setup "$hexdir/build" "$hexdir/src" -Dprefix=/usr -Db_lto=true
meson compile -C "$hexdir/build"
DESTDIR="$hexdir/staging" meson install --no-rebuild -C "$hexdir/build"
install -Dm644 "$repo_dir"/specs/hexagonrpcd-samsung/patches/10-fastrpc.rules \
    -t "$hexdir/staging/usr/lib/udev/rules.d/"
cp -a "$hexdir/staging/." "$rootfs/"
# The patch installs units to libdir/systemd/system, which lands in
# usr/lib64 on Fedora — a path systemd does not search. Move them next to
# every other system unit.
if [ -d "$rootfs/usr/lib64/systemd/system" ]; then
    mkdir -p "$rootfs/usr/lib/systemd/system"
    mv "$rootfs"/usr/lib64/systemd/system/* "$rootfs/usr/lib/systemd/system/"
    rmdir "$rootfs/usr/lib64/systemd/system" "$rootfs/usr/lib64/systemd" \
        2>/dev/null || true
fi

echo ">>> Building iio-sensor-proxy 3.9 with libssc support"
# Fedora's own build may not link libssc; build it exactly like the pmOS port
# (libssc + notify-slow-sensor-discovery patch).
ispdir="$(mktemp -d)"
curl -sfL "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/3.9/iio-sensor-proxy-3.9.tar.gz" \
    | tar xz -C "$ispdir" --strip-components=1
patch -d "$ispdir" -p1 \
    < "$repo_dir"/specs/iio-sensor-proxy-libssc/patches/notify-slow-sensor-discovery.patch
meson setup "$ispdir/build" "$ispdir" -Dprefix=/usr
meson compile -C "$ispdir/build"
DESTDIR="$ispdir/staging" meson install --no-rebuild -C "$ispdir/build"
cp -a "$ispdir/staging/." "$rootfs/"

# hexagonrpcd units run as the fastrpc system user (Alpine pre-install equivalent)
groupadd --root "$rootfs" -r fastrpc
useradd --root "$rootfs" -r -g fastrpc -s /usr/sbin/nologin -d / fastrpc

echo ">>> Applying device overlay"
cp -a "$repo_dir/rootfs/overlay/." "$rootfs/"

echo ">>> Injecting local assets"
if [ -f "$firmware_tar" ]; then
    tar xzf "$firmware_tar" -C "$rootfs"
else
    missing_assets+=("firmware.tar.gz (Wi-Fi/BT/ADSP/audio blobs: run rootfs/fetch-local-assets.sh)")
fi
if [ -d "$assets/modules/$kver" ]; then
    mkdir -p "$rootfs/usr/lib/modules"
    cp -a "$assets/modules/$kver" "$rootfs/usr/lib/modules/"
    depmod -b "$rootfs" "$kver"
elif [ -n "$kernel_rpm" ]; then
    :   # kernel modules come from the pinned RPM below
else
    missing_assets+=("modules/$kver (kernel modules matching eMMC kernel: run rootfs/fetch-local-assets.sh)")
fi

if [ -n "$kernel_rpm" ]; then
    echo ">>> Installing the pinned kernel RPM (module tree + /boot)"
    # Keeps the rootfs self-contained: modules signed by the same CI run as
    # the boot bundle, so Wi-Fi/BT load on first boot without any pairing
    # step (see the README rule about bundle/RPM pairing).
    dnf -y --installroot="$rootfs" --use-host-config --setopt=tsflags=nodocs install "$kernel_rpm"
    depmod -b "$rootfs" -a "${kver}-gts9wifi" 2>/dev/null || true
fi

echo ">>> Base system configuration"
cat > "$rootfs/etc/fstab" <<EOF
UUID=$root_uuid /     ext4 defaults 0 0
UUID=$boot_uuid /boot ext2 defaults,nodev,nosuid,noexec 0 0
EOF
echo "gts9-fedora" > "$rootfs/etc/hostname"
if [ -f "$rootfs/etc/selinux/config" ]; then
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$rootfs/etc/selinux/config"
else
    echo "    WARN: /etc/selinux/config not found; SELinux left at default" >&2
fi

# USB gadget network comes up configured by the pmOS initramfs; keep the
# address after switch_root so first-boot debugging works over SSH.
mkdir -p "$rootfs/etc/NetworkManager/system-connections"
cat > "$rootfs/etc/NetworkManager/system-connections/usb0.nmconnection" <<EOF
[connection]
id=usb0
interface-name=usb0
type=ethernet
autoconnect=true

[ipv4]
address1=172.16.42.1/24
method=manual

[ipv6]
method=disabled
EOF
chmod 600 "$rootfs/etc/NetworkManager/system-connections/usb0.nmconnection"

echo ">>> Users"
echo "root:${build_user}" | chpasswd --root "$rootfs"
useradd --root "$rootfs" -m -G wheel -s /bin/bash "$build_user"
# useradd's skel copy can abort partway (observed "Bad file descriptor" for
# one entry in the CI container, leaving only a partial home): populate the
# home directory explicitly and hand it to the first user's uid/gid (1000).
mkdir -p "$rootfs/home/$build_user"
cp -a "$rootfs/etc/skel/." "$rootfs/home/$build_user/"
chown -R 1000:1000 "$rootfs/home/$build_user"
echo "${build_user}:${build_user}" | chpasswd --root "$rootfs"
if [ -f "$assets/ssh-key.pub" ]; then
    home="$rootfs/home/$build_user"
    install -Dm600 -o 1000 -g 1000 "$assets/ssh-key.pub" "$home/.ssh/authorized_keys"
else
    missing_assets+=("ssh-key.pub (your public key for passwordless first-boot SSH)")
fi

echo ">>> Enabling services"
if [ "$desktop" = "gnome" ]; then
    systemctl --root="$rootfs" enable gdm >/dev/null 2>&1 \
        || echo "    WARN: gdm not found" >&2
    systemctl --root="$rootfs" set-default graphical.target >/dev/null 2>&1 || true
fi
for unit in \
    sshd NetworkManager \
    hexagonrpcd-adsp-rootpd \
    pd-mapper \
    gts9wifi-wait-sensor-proxy \
    gts9wifi-bt-provision bluetooth gts9wifi-mem-reclaim \
    gts9wifi-adsp-boot \
    gts9wifi-panel-coldboot-recover \
    gts9wifi-grow-rootfs \
    gts9wifi-usb-net gts9wifi-wifi-recover \
    mnt-vendor-persist.mount vendor-dsp.mount vendor-firmware_mnt.mount
do
    systemctl --root="$rootfs" enable "$unit" >/dev/null 2>&1 \
        || echo "    WARN: unit not found (check name after hexagonrpcd patch): $unit"
done
# Deliberately NOT enabled, matching hard-won pmOS experience:
# - hexagonrpcd-adsp-sensorspd: pulls in gts9wifi-adsp-boot via the hexagonfs
#   drop-in's Requires=; the ADSP start can hang or reset the SoC, and doing
#   it while panel-coldboot-recover runs its pm_test suspend froze the board
#   completely.  Start it manually and watch.
# - gts9wifi-adsp-boot.service: same, ships disabled in the pmOS port.
# - gts9wifi-bt-revive.service: started by hand when the WCN sequencer
#   takes hci0 down.
# The preset in overlay/usr/lib/systemd/system-preset/85-gts9wifi.preset
# keeps first-boot preset-all from stripping the enablement above.
# TODO(phase-1.5): vendor make-dynpart-mappings and enable
# gts9wifi-android-parts.service + vendor.mount (super -> erofs /vendor).

echo ">>> Cleaning"
rm -rf "$rootfs/var/cache/dnf" "$rootfs/var/cache/rpm" "$rootfs/var/log/dnf*"
rm -f "$rootfs/etc/machine-id" "$rootfs/var/lib/systemd/random-seed"

echo ">>> Packing"
rpm -qa --root "$rootfs" --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort \
    > "$outdir/rootfs-manifest.txt"
archive="$outdir/gts9wifi-fedora-$fedora_release-rootfs.tar.gz"
tar -C "$rootfs" -czf "$archive" .

echo ">>> Done: $archive"
if [ "${#missing_assets[@]}" -gt 0 ]; then
    echo ""
    echo ">>> NOTE: not provided in this build:"
    for m in "${missing_assets[@]}"; do echo "    - $m"; done
    echo ">>> (release CI builds provide the firmware payload and kernel RPM;"
    echo ">>> only a personal ssh key is ever local-only.)"
fi
