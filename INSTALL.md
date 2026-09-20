# Installing Fedora on the Galaxy Tab S9 Wi-Fi (SM-X710)

End-to-end, from a tablet with an unlocked bootloader to a booting Fedora
system. The root lives in **internal storage**: the `userdata` partition is
reformatted as one ext4 carrying the boot cmdline's root UUID, so no microSD
is needed. An SD card prepared by `mk-sd-card.sh` with the same UUID remains a
bootable rescue card — **never boot with both inserted**.

- **Boot-chain partitions** (`boot`, `init_boot`, `vendor_boot`, `dtbo`) carry
  this repo's Android boot-image-v4 bundle: mainline kernel + board DTB +
  dracut initramfs + the kernel cmdline (`root=UUID=… rw`).
- **`userdata`** (~105 GB) carries the Fedora root as a single ext4.

> **This destroys Android's data** — the stock f2fs is reformatted. Android
> stays restorable later via TWRP *Format Data* or an Odin firmware flash. The
> boot-chain partitions and recovery are never touched by anything here.

## Prerequisites

1. **SM-X710 with an unlocked bootloader and TWRP in the recovery partition.**
   Unlocking the bootloader and flashing TWRP is outside this guide.
2. **A Linux PC with `adb`**, connected by USB, with this repo cloned.
3. **The firmware payload** — only needed when building the rootfs yourself;
   the released rootfs and the firmware asset on the kernel release already
   contain everything. The blobs are extracted from the tablet's own stock
   partitions (`apnhlos`, `dsp`, `persist`); without them Wi-Fi, Bluetooth,
   audio and the ADSP stay dead.

## 1. Get or build the rootfs

**Easiest:** download the turnkey rootfs tarball from
[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases)
(`rootfs-f44-gnome-…`, ~1.8 GB). It already contains GNOME, the device stack,
all firmware and the kernel modules matching the boot bundle — continue with
step 2.

Building it yourself (GitHub Actions → **Fedora rootfs** → *Run workflow*, or
locally in an arm64 Fedora container):

```sh
./rootfs/fetch-local-assets.sh
podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
    ./rootfs/build-rootfs.sh
```

Optional environment: `GTS9_USER` names the first-boot user (default
`fedora`). An SSH public key at `local-assets/ssh-key.pub` is installed when
present. `GTS9_DESKTOP=core` builds a small headless debug image.

## 2. Install the rootfs to internal storage (TWRP)

Boot TWRP (Volume Up + Power past the Samsung logo), connect USB, then from
the PC:

```sh
./rootfs/mk-internal-storage.sh <path-to>/gts9wifi-fedora-44-rootfs.tar.gz
```

The script verifies the device is in recovery, checks the codename
(`gts9`/`gts9wifi`) and model (`SM-X710`), resolves `userdata` by partition
label, checks its size, prints a prominent warning about the data loss, and
requires typing `DESTROY` before it formats. It also applies the local-assets
extras when present (firmware payload, kernel modules, SSH key — the same
injections `mk-sd-card.sh` does; the release tarball already carries all
three). It never touches any other partition and never reboots the tablet.

## 3. Get the boot bundle

Download the **TWRP flash zip** from
[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases) (for example
`gts9wifi-fedora-7.2.0-gts9wifi.zip`). It contains the five boot-chain
images at exact partition sizes plus the installer; its `SHA256SUMS` file
lists each image.

## 4. Flash from TWRP

1. Boot TWRP: power off, then hold **Volume Up + Power** past the Samsung
   logo. (Volume Down + USB is download mode — not what you want.)
2. Push the zip from the PC:
   `adb push gts9wifi-fedora-7.2.0-gts9wifi.zip /tmp/inst.zip`
3. TWRP → *Install* → select `/tmp/inst.zip` (or
   `adb shell twrp install /tmp/inst.zip`). The installer verifies the device
   (`gts9`/`gts9wifi`, `SM-X710`) and every partition size before writing
   `boot`, `init_boot`, `vendor_boot` and `dtbo`; it never touches `userdata`,
   `super`, EFS or the recovery, and it preserves a read-only `vbmeta` that
   already carries AVB flags 2. It does not reboot on its own.
4. Reboot → *System*.

## 5. First boot

**Remove any inserted microSD** (a rescue card carries the same root UUID —
exactly one of the two must be present). The first boot takes a couple of
minutes: the panel cold-boot recovery runs a platform PM cycle, and Wi-Fi and
Bluetooth power up through the WCN sequencer.

The root filesystem is created at full partition size — nothing to grow. A USB
debug network appears as `usb0`:

```sh
read -s -p "tablet password: " PW; echo
ssh -o "StrictHostKeyChecking=accept-new" fedora@172.16.42.1
```

Configure Wi-Fi from GNOME Settings (or
`nmcli device wifi connect "<SSID>" password "<pw>"`). You are in a full Fedora
Workstation GNOME desktop; the clock syncs automatically once Wi-Fi connects.

## 6. Updating the kernel / boot bundle

Grab the newer release zip and reflash it from TWRP — then **install the
matching kernel RPM on the tablet**:

```sh
curl -LO <release>/linux-gts9wifi-<ver>.aarch64.rpm
sudo rpm -Uvh linux-gts9wifi-<ver>.aarch64.rpm
```

Take the bundle and the RPM from the same release: the kernel's version magic
has to match the modules on the rootfs or they will not load, and the first
thing you notice is Wi-Fi and Bluetooth being dead.

## Rollback

Keep the previous release zip — reflashing it from TWRP restores the previous
boot chain in about two minutes. The installer never writes anything outside
the four boot partitions, so the internal root survives every bundle reflash.

If the internal root itself is broken, a microSD prepared by `mk-sd-card.sh`
boots the same system by the shared root UUID (insert it *instead of*, never
*in addition to*, the internal root). Returning to Android: TWRP → *Format
Data*, or a full Odin firmware flash.

## Known issues on first boot

- **Bluetooth needs one extra reboot** after flashing a new boot bundle: the
  address provisioning patches the bundle DTBs on the first boot, and the
  address applies from the next one.
- **Hardware video decode works**, but see
  [Hardware Notes](docs/Hardware-Notes.md#hardware-video-decode) for
  which players can actually reach the VPU.
- `/vendor` (the Android `super` partition) is **not** mounted.
- SELinux runs **permissive**.

The full list is in [Known Issues](docs/Known-Issues.md).
