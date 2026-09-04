# Installing Fedora on the Galaxy Tab S9 Wi-Fi (SM-X710)

End-to-end, from a tablet with an unlocked bootloader to a booting Fedora
system. The layout produced here:

- **eMMC boot partitions** (`boot`, `init_boot`, `vendor_boot`, `dtbo`) carry
  this repo's Android boot-image-v4 bundle: the mainline kernel with the
  board DTB, a dracut initramfs, and the kernel cmdline (`root=UUID=… rw`).
- **microSD** carries the Fedora root (`/` on p2) plus a small ext2 `/boot`.
  Stock Android data on the eMMC is not touched.

Estimated time: ~1 hour, most of it unattended.

## Prerequisites

1. **SM-X710 with an unlocked bootloader and TWRP in the recovery
   partition.** Unlocking/flashing TWRP is outside this guide; the
   [pmos-gts9wifi-build](https://github.com/nacht20-de/pmos-gts9wifi-build)
   and UBports gts9 ports describe it for this device.
2. **A spare microSD** (16 GB+, will be erased) — your daily card is never
   touched.
3. **A Linux PC with `adb`**, connected by USB.
4. **The firmware payload.** The Wi-Fi/BT/ADSP/audio/sensors blobs are
   extracted from the tablet's own stock partitions (apnhlos, dsp, persist)
   by the port kit (`port-kit/firmware-extract/`). This step currently
   requires either a running postmarketOS install on the tablet (then
   `rootfs/fetch-local-assets.sh` pulls everything over USB) or a local copy
   of the port kit. Without it the build still completes, but Wi-Fi, BT,
   audio and the ADSP will be dead on the tablet.

## 1. Get or build the rootfs

**Easiest**: download the turnkey rootfs tarball from
[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases)
(`rootfs-f44-gnome-…`, ~1.8 GB). It already contains GNOME, the device
stack, all firmware and the kernel modules matching the boot bundle —
continue with step 2.

Building it yourself (GitHub Actions → **"Fedora rootfs"** → Run workflow,
or locally in an arm64 Fedora container):

    ./rootfs/fetch-local-assets.sh
    podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
        ./rootfs/build-rootfs.sh

Optional environment: `GTS9_USER` names the first-boot user
(default `fedora`, password equals the username — change it on first
login; an SSH key from `local-assets/ssh-key.pub` is installed when
present). `GTS9_DESKTOP=core` builds a small headless debug image.

## 2. Write the SD card

    sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX

Use the spare card's device node. The script labels the partitions with the
UUIDs the boot bundle's cmdline expects; on first boot the root filesystem
grows to fill the card automatically.

## 3. Get the boot bundle

Download the **TWRP flash zip** from
[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases)
(e.g. `gts9wifi-fedora-7.2.0-rc3-gts9wifi.zip`). It contains the five
boot-chain images at exact partition sizes plus the installer; its SHA256SUMS
file lists each image.

## 4. Flash from TWRP

1. Boot TWRP: power off, then hold **Volume Up + Power** past the Samsung
   logo. (Volume Down + USB is download mode — not what you want.)
2. Copy the zip onto the SD card (from Fedora: `/home/<user>/`; from the PC:
   `adb push <zip> /sdroot/...` or use TWRP's MTP).
3. TWRP → Install → select the zip. The installer verifies the device
   (gts9/gts9wifi, SM-X710) and every partition size before writing
   `boot`, `init_boot`, `vendor_boot`, `dtbo`; it never touches userdata,
   super, EFS or the recovery, and it preserves a read-only vbmeta that
   already carries AVB flags 2. It does not reboot on its own.
4. Reboot → System.

## 5. First boot

The first boot takes a couple of minutes: the root filesystem is grown to
fill the card, the panel cold-boot recovery runs a platform PM cycle, and
Wi-Fi/BT power up through the WCN sequencer (the AOP PDC init table in the
DTB handles cold starts). A USB debug network appears as `usb0`:

    ssh fedora@172.16.42.1         # password: fedora (or your injected key)

Configure Wi-Fi with `nmcli device wifi connect "<SSID>" password "<pw>"`.
From here on the tablet is a normal (headless-core) Fedora system: add your
packages, a desktop, etc.

## 6. Updating the kernel/boot bundle

Grab the newer release zip and reflash it from TWRP — then **install the
matching kernel RPM on the tablet**:

    curl -LO <release>/linux-gts9wifi-<ver>.aarch64.rpm
    sudo rpm -Uvh linux-gts9wifi-<ver>.aarch64.rpm

Every CI run signs its modules with a fresh ephemeral key: a new boot.img
with the previous module tree fails to load Wi-Fi/BT modules with
"Operation not permitted". Flashing bundle + RPM from the same release
always matches.

## Rollback

Keep the previous release zip — reflashing it from TWRP restores the
previous boot chain in two minutes. The installer never writes anything
outside the four boot partitions, so the SD root and stock Android data
survive every step here.

## Known issues on first boot

- **Bluetooth** completes kernel-side setup but does not register with
  bluez management (`btmgmt` shows no index) — pairing is not usable yet.
- **Sensors** (accelerometer/ambient light) are dead: SSC discovery never
  completes, same as on pmOS.
- `/vendor` (the super partition) is not mounted; SELinux is permissive.
