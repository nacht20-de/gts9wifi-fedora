# Fedora on the Samsung Galaxy Tab S9 Wi-Fi (SM-X710)
<img width="2560" height="1600" alt="Screenshot From 2026-09-19 21-12-31" src="https://github.com/user-attachments/assets/cfde72fc-4f13-4597-8138-80e1f1823c54" />
<img width="2560" height="1600" alt="Screenshot From 2026-09-19 21-11-57" src="https://github.com/user-attachments/assets/02131237-9f32-4939-8583-e29a04e767c9" />

Mainline Linux (stable **7.2.6** plus a small patch set) with a **Fedora 44**
userland on the Samsung Galaxy Tab S9 Wi-Fi — codename `gts9wifi`, model
`SM-X710`.

The tablet boots through its **stock Android boot chain** into a Fedora root on
the **internal UFS storage**. No microSD is required, and there is no
second-stage bootloader: the bootloader loads a mainline kernel + board DTB +
dracut initramfs from the `boot`/`init_boot`/`vendor_boot` partitions, and that
initramfs mounts the Fedora root by UUID.

This repo builds everything for that: the rootfs, a kernel RPM, the Android
boot-image-v4 bundle, and a TWRP flash zip.

> ⚠️ **Installing destroys Android's data** — the `userdata` partition is
> reformatted. Android remains restorable via TWRP *Format Data* or an Odin
> firmware flash. The boot-chain partitions and recovery are never touched.

---

## 📖 Documentation is in the wiki

The [**wiki**](https://github.com/troikoss/gts9wifi-fedora/wiki) is the single
source of truth for anything beyond this file:

| Page | Read it when you want to… |
|---|---|
| [**Home**](https://github.com/troikoss/gts9wifi-fedora/wiki/Home) | see the full hardware status table and what currently works |
| [**Installation**](https://github.com/troikoss/gts9wifi-fedora/wiki/Installation) | actually install it, update it, or roll back |
| [**Known Issues**](https://github.com/troikoss/gts9wifi-fedora/wiki/Known-Issues) | check whether your problem is already known — the live issue register |
| [**TODO**](https://github.com/troikoss/gts9wifi-fedora/wiki/TODO) | find something to work on |
| [**Porting Guide**](https://github.com/troikoss/gts9wifi-fedora/wiki/Porting-Guide) | port Linux to a **different** Android tablet |
| [**Hardware Notes**](https://github.com/troikoss/gts9wifi-fedora/wiki/Hardware-Notes) | debug one subsystem on this device |

If you are porting another tablet, the
[Porting Guide](https://github.com/troikoss/gts9wifi-fedora/wiki/Porting-Guide)
is the transferable part — the boot chain, kernel, firmware, rootfs and
verification discipline — and it is written so the specifics are examples
rather than requirements.

---

## Status at a glance

Verified on hardware end to end: cold start, GPU acceleration from the first
probe, ambient-light sensing over D-Bus, and password login.

| Working | Partial / in progress |
|---|---|
| Display (2560×1600 AMOLED), touchscreen, double-tap-to-wake | S Pen tilt sensor |
| Wi-Fi (5 GHz included), Bluetooth | Charging bypass on 25 W+ adapters — needs a desktop patch |
| Speakers + DMIC capture, with speaker-protection DSP firmware | Under-display fingerprint — secure processor is up, blocked at the TEE |
| Battery/charging, Type-C PD, USB-C DisplayPort alt-mode | `/vendor` (Android `super`) is not mounted |
| GPU (Adreno 740), sensors incl. auto-rotate, both cameras | No autofocus anywhere in the camera stack |
| Hardware video decode (VP9 / H.264 / HEVC) | Only some applications can reach the VPU — see [Home](https://github.com/troikoss/gts9wifi-fedora/wiki/Home) |
| Power/volume keys, book-cover lid, suspend | SELinux runs permissive |

The authoritative, always-current version of this table is on the
[wiki Home](https://github.com/troikoss/gts9wifi-fedora/wiki/Home).

---

## Getting the images

[**Releases**](https://github.com/nacht20-de/gts9wifi-fedora/releases) carries
everything needed. The release artifacts live on the **parent** repository —
this repo is a fork of [`nacht20-de/gts9wifi-fedora`](https://github.com/nacht20-de/gts9wifi-fedora)
and carries newer work on top of it:

- **`rootfs-f44-gnome-…`** — the turnkey rootfs tarball (~1.8 GB): GNOME
  Workstation plus gdm, the device stack, all device firmware, and kernel
  modules matching the boot bundle. Default login is `fedora` / `fedora`.
- **`kernel-…-gts9wifi-…`** — the TWRP flash zip (boot bundle), the kernel RPM,
  and the firmware payload asset.

CI artifacts also exist per successful Actions run. Full walk-through:
[Installation](https://github.com/troikoss/gts9wifi-fedora/wiki/Installation).

---

## Building from source

Everything builds on native arm64 in GitHub Actions (`workflow_dispatch`):
**Fedora rootfs**, **Kernel build** (RPM + initramfs + bundle + TWRP zip), and
**Boot bundle** (fast path against a pinned released RPM).

Locally, the rootfs build needs an arm64 Fedora container:

```sh
./rootfs/fetch-local-assets.sh
podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
    ./rootfs/build-rootfs.sh
sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX
```

`GTS9_USER` (default `fedora`) names the first-boot user, and
`GTS9_DESKTOP=core` builds a small headless debug image.

Device blobs are **never committed**. Everything the rootfs needs is either
extracted from the tablet's own stock partitions (`apnhlos`, `dsp`, `persist`)
or fetched by `rootfs/fetch-local-assets.sh` from a pinned source with a
verified checksum.

---

## ⚠️ The one rule when updating

**A new boot bundle must be paired with its matching kernel RPM on the rootfs.**

```sh
sudo rpm -Uvh linux-gts9wifi-<ver>.aarch64.rpm
```

Every CI run signs its modules with a fresh ephemeral key, so mixing a new
`boot.img` with an older module tree fails with *Operation not permitted* —
and the symptom is Wi-Fi and Bluetooth simply not loading. Flashing the bundle
and installing the RPM from the **same release** always matches.

---

## Repository layout

| Path | Contents |
|---|---|
| `rootfs/` | `build-rootfs.sh` (Fedora aarch64 rootfs build), `overlay/` (device services, mounts, udev rules, ALSA UCM), `mk-internal-storage.sh` (internal-storage install), `mk-sd-card.sh` (rescue SD card), `fetch-local-assets.sh` (device firmware/modules/SSH key) |
| `kernel/` | `prepare.sh` + `kernel.spec` (kernel RPM), the port patches, out-of-tree drivers, board DTS, config fragment |
| `boot/` | `build-bundle.sh` (Android boot-image-v4 bundle), cmdline, bootconfig, dracut config, initramfs USB-net module |
| `specs/` | RPM specs carrying the vendored Samsung patches (`hexagonrpcd`, `iio-sensor-proxy`, `libcamera-hi1337`) |
| `tools/` | vendored AOSP `avbtool`/`mkbootimg`, TWRP zip packer and installer |

The most intricate corners have their own notes: `kernel/files/spu/spss-irq/` and
`specs/libcamera-hi1337/` each carry a `README.md`.

---

## How it works, in one paragraph

Samsung's bootloader loads `vendor_boot`, whose DTB is the one that actually
gets used and whose cmdline carries `root=UUID=…`. `dtbo` is deliberately
invalid so the bootloader falls back to the appended DTB, and `vbmeta` is
zeroed so verified boot is off. The kernel is mainline plus out-of-tree drivers
for the touchscreen, panel, charger, USB-PD, fuel gauge, redriver and pen
digitizer, and the initramfs carries the GPU's zap/GMU firmware because the GPU
probes before the root filesystem exists. Several Android partitions are still
needed **at runtime**, not just at first boot — `persist` is mounted
read-write because Samsung's sensor registry and Wi-Fi calibration live there.

The details, and the traps, are in the
[Porting Guide](https://github.com/troikoss/gts9wifi-fedora/wiki/Porting-Guide)
and [Hardware Notes](https://github.com/troikoss/gts9wifi-fedora/wiki/Hardware-Notes).

---

## Contributing

- **Check [Known Issues](https://github.com/troikoss/gts9wifi-fedora/wiki/Known-Issues)
  first** — issue numbers are stable and referenced by build scripts, so they
  are never renumbered and never reused.
- **[TODO](https://github.com/troikoss/gts9wifi-fedora/wiki/TODO)** lists what is
  actually outstanding, with a note on where each investigation stopped.
- Issue numbers in commits and scripts refer to that register, not to GitHub
  issue numbers.

---

## Prior art

This is not the only port for this device, and both sibling projects were read
while working on it:

- **Azkali's gts9wifi work** — a mainline tree plus a firmware payload.
- **agcarbajo's port** — kernel and userspace subsystems.

---

## License

MIT — see [LICENSE](LICENSE).

Note: files under `kernel/` are kernel sources and carry their own SPDX
identifiers (GPL-2.0 for drivers, BSD-3-Clause for device trees); those
identifiers govern those files. This LICENSE covers the repo's own tooling.
