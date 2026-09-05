# Fedora on the Samsung Galaxy Tab S9 Wi-Fi (gts9wifi, SM-X710)

Mainline Linux (7.2-rc3 + port patches) with a Fedora 44 userland on the
Tab S9 Wi-Fi: native display, touch, Wi-Fi, speakers, battery and
USB-C/Type-C PD, booting from the eMMC Android boot chain into a Fedora
root on the microSD.  This repo builds everything for Fedora: the rootfs,
a kernel RPM, the Android boot-image-v4 bundle, and a TWRP flash zip.

Verified on hardware end to end: cold start, GPU acceleration from first
probe, ambient-light sensing over D-Bus, password login.

## What works

| Area | Status |
|---|---|
| Display (2560×1600 AMOLED, DSI + DSC) | ✅ a cold-boot revive service runs automatically |
| Touchscreen | ✅ |
| S Pen digitizer | ⚠️ detected, but input behaves erratically |
| Wi-Fi (QCA6490 / ath11k) | ✅ cold start fixed via the AOP PDC init table |
| Bluetooth | ✅ native BD address auto-provisioned (applies from the second boot after a bundle flash) |
| Speakers (4× CS35L45), DMIC capture | ✅ volume capped ~-19 dB (speaker-protection DSP not loaded) |
| Battery / charging incl. PPS (SM5714 + SM5440) | ✅ |
| USB (gadget debug net, host), Type-C PD, docks | ✅ |
| USB-C DisplayPort altmode | ✅ with deferred-HPD workaround |
| GPU (Adreno 740) | ✅ Samsung-signed zap/GMU firmware, in the initramfs |
| Hardware video decode (iris) | ❌ Samsung-signed vpu30_4v.mbn not yet sourced |
| Power/volume keys, book-cover lid, suspend (s2idle) | ✅ |
| Sensors (SSC: accelerometer, rotation vector, ambient light) | ⚠️ SSC fully alive; ambient light serves over D-Bus; screen auto-rotate pending an upstream iio-sensor-proxy/libssc fix |
| Camera | ❌ no drivers |
| /vendor super partition (erofs) | ❌ needs make-dynpart-mappings port |
| SELinux | permissive |

## Installation

See [INSTALL.md](INSTALL.md) for the full walk-through. In short: build (or
download) the Fedora SD-card rootfs, flash the boot bundle to the eMMC boot
partitions from TWRP, and boot with the card inserted. USB networking comes
up on usb0 for debugging: `ssh fedora@172.16.42.1`.

**The one rule when updating:** a new boot bundle must be paired with its
matching kernel RPM on the rootfs (`dnf install ./linux-gts9wifi-*.rpm`).
Each CI run signs modules with a fresh ephemeral key, so mixing a new
boot.img with an old module tree fails with "Operation not permitted".

## Getting the images

[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases) carries
everything needed:

- **`rootfs-f44-gnome-…`** — the turnkey rootfs tarball: GNOME Workstation
  + gdm, the device stack, all device firmware and the kernel modules
  matching the boot bundle. Login `fedora` / `fedora`.
- **`kernel-…-gts9wifi-3`** — the TWRP flash zip (boot bundle), the
  kernel RPM and the firmware payload asset.

Write the rootfs to a microSD with `rootfs/mk-sd-card.sh`, flash the TWRP
zip, boot — see [INSTALL.md](INSTALL.md). CI artifacts also exist per
successful
[Actions](https://github.com/nacht20-de/gts9wifi-fedora/actions) run.

## Layout

- `rootfs/` — build-rootfs.sh (Fedora aarch64 rootfs build), overlay/
  (device services, mounts, udev rules, UCM),
  mk-sd-card.sh (SD assembly), fetch-local-assets.sh (device firmware/
  modules/ssh key — needs the port kit).
- `kernel/` — prepare.sh + kernel.spec (kernel RPM), the 18 port patches,
  out-of-tree drivers, board DTS and config fragment.
- `boot/` — build-bundle.sh (Android boot-image-v4 bundle), cmdline,
  bootconfig, the dracut config and the initramfs USB-net module.
- `specs/` — RPM specs with the vendored Samsung patches (hexagonrpcd,
  iio-sensor-proxy).
- `tools/` — vendored AOSP avbtool/mkbootimg, TWRP zip packer + installer.
- `docs/` — PORT-KIT.md (internal extraction inventory; developer notes).

## Building from source

Everything builds on native arm64 in GitHub Actions (`workflow_dispatch`):
"Fedora rootfs", "Kernel build" (RPM + initramfs + bundle + TWRP zip) and
"Boot bundle" (fast path against a pinned released RPM). Locally, the rootfs
build needs an arm64 Fedora container:

    ./rootfs/fetch-local-assets.sh          # firmware/modules/ssh key from the device
    podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
        ./rootfs/build-rootfs.sh
    sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX

`GTS9_USER` (default `fedora`) names the first-boot user. Device blobs are
never committed; see [INSTALL.md](INSTALL.md) for the firmware story.

libssc and pd-mapper are not in Fedora and are built from source; hexagonrpcd
carries the port's Samsung sensor-registry patches; iio-sensor-proxy builds
against libssc.
