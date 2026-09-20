# Fedora on the Samsung Galaxy Tab S9 Wi-Fi (SM-X710)

<img width="2560" height="1600" alt="Screenshot From 2026-09-19 21-12-31" src="https://github.com/user-attachments/assets/cfde72fc-4f13-4597-8138-80e1f1823c54" />
<img width="2560" height="1600" alt="Screenshot From 2026-09-19 21-11-57" src="https://github.com/user-attachments/assets/02131237-9f32-4939-8583-e29a04e767c9" />

Mainline Linux (stable **7.2** plus a small patch set) with a **Fedora 44**
userland on the Samsung Galaxy Tab S9 Wi-Fi — codename `gts9wifi`, model
`SM-X710`.

The tablet boots through its **stock Android boot chain** into a Fedora root on
the **internal UFS storage**. No microSD is required, and there is no
second-stage bootloader: the bootloader loads a mainline kernel + board DTB +
dracut initramfs from the `boot`/`init_boot`/`vendor_boot` partitions, and that
initramfs mounts the Fedora root by UUID.

This repo builds everything for that: the rootfs, a kernel RPM, the Android
boot-image-v4 bundle, and a TWRP flash zip.

> **Installing destroys Android's data** — the `userdata` partition is
> reformatted. Android remains restorable via TWRP *Format Data* or an Odin
> firmware flash. The boot-chain partitions and recovery are never touched.

---

## Documentation

[INSTALL.md](INSTALL.md) is the full install walk-through. Everything else
lives in `docs/`:

| Page | Contents |
|---|---|
| [Known Issues](docs/Known-Issues.md) | the issue register referenced by commits and scripts |
| [Hardware Notes](docs/Hardware-Notes.md) | per-subsystem debugging notes |
| [Device Controls](docs/Device-Controls.md) | the double-tap-to-wake and fast-charging switches |
| [Port Kit](docs/PORT-KIT.md) | the extraction inventory behind the port (developer notes) |

---

## Status

Verified on hardware end to end: cold start, GPU acceleration from the first
probe, ambient-light sensing over D-Bus, password login.

| Working | Partial / in progress |
|---|---|
| Display (2560×1600 AMOLED), touchscreen, double-tap-to-wake | S Pen tilt sensor |
| Wi-Fi (5 GHz included), Bluetooth | Charging bypass on 25 W+ adapters — needs a desktop patch |
| Speakers + DMIC capture, with speaker-protection DSP firmware | Under-display fingerprint — secure processor is up, blocked at the TEE |
| Battery/charging, Type-C PD, USB-C DisplayPort alt-mode | `/vendor` (Android `super`) is not mounted |
| GPU (Adreno 740), sensors incl. auto-rotate, both cameras | No autofocus anywhere in the camera stack |
| Hardware video decode (VP9 / H.264 / HEVC) | Only some applications can reach the VPU — see [Hardware Notes](docs/Hardware-Notes.md) |
| Power/volume keys, book-cover lid, suspend | SELinux runs permissive |

---

## Getting the images

[Releases](https://github.com/nacht20-de/gts9wifi-fedora/releases) carries
everything needed:

- **`rootfs-f44-gnome-…`** — the turnkey rootfs tarball (~1.8 GB): GNOME
  Workstation plus gdm, the device stack, all device firmware, and kernel
  modules matching the boot bundle. Default login is `fedora` / `fedora`.
- **`kernel-…-gts9wifi-…`** — the TWRP flash zip (boot bundle), the kernel RPM,
  and the firmware payload asset.

The full walk-through is in [INSTALL.md](INSTALL.md).

---

## Building from source

Everything builds on native arm64 in GitHub Actions (`workflow_dispatch`):
**Fedora rootfs**, **Kernel build** (RPM + initramfs + bundle + TWRP zip), and
**Boot bundle** (fast path against a pinned released RPM). Locally, the rootfs
build needs an arm64 Fedora container:

```sh
./rootfs/fetch-local-assets.sh
podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
    ./rootfs/build-rootfs.sh
sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX
```

`GTS9_USER` (default `fedora`) names the first-boot user, and
`GTS9_DESKTOP=core` builds a small headless debug image.

Device blobs are never committed: everything the rootfs needs is either
extracted from the tablet's own stock partitions (`apnhlos`, `dsp`, `persist`)
or fetched from a pinned source with a verified checksum.

---

## Updating

A new boot bundle must be paired with its matching kernel RPM on the rootfs:

```sh
sudo rpm -Uvh linux-gts9wifi-<ver>.aarch64.rpm
```

Take the bundle and the RPM from the same release. The kernel's version magic
has to match the modules on the rootfs or they will not load — and the first
thing you notice is Wi-Fi and Bluetooth being dead.

---

## Layout

| Path | Contents |
|---|---|
| `rootfs/` | `build-rootfs.sh` (Fedora aarch64 rootfs build), `overlay/` (device services, mounts, udev rules, ALSA UCM), `mk-internal-storage.sh` (internal-storage install), `mk-sd-card.sh` (rescue SD card), `fetch-local-assets.sh` (device firmware/modules/SSH key) |
| `kernel/` | `prepare.sh` + `kernel.spec` (kernel RPM), the port patches, out-of-tree drivers, board DTS, config fragment |
| `boot/` | `build-bundle.sh` (Android boot-image-v4 bundle), cmdline, bootconfig, dracut config, initramfs USB-net module |
| `specs/` | RPM specs carrying the vendored patches (`hexagonrpcd`, `iio-sensor-proxy`, `libcamera-hi1337`) |
| `tools/` | vendored AOSP `avbtool`/`mkbootimg`, TWRP zip packer and installer |
| `docs/` | issue register, hardware notes, device controls, port kit |

`kernel/files/spu/spss-irq/` and `specs/libcamera-hi1337/` carry their own
READMEs.

---

## How it boots

Samsung's bootloader loads `vendor_boot`, whose DTB is the one that actually
gets used and whose cmdline carries `root=UUID=…`. `dtbo` is deliberately
invalid so the bootloader falls back to the appended DTB, and `vbmeta` is
zeroed so verified boot is off. The kernel is mainline plus out-of-tree drivers
for the touchscreen, panel, charger, USB-PD, fuel gauge, redriver and pen
digitizer, and the initramfs carries the GPU's zap/GMU firmware because the GPU
probes before the root filesystem exists. Several Android partitions are still
needed **at runtime**, not just at first boot — `persist` is mounted read-write
because Samsung's sensor registry and Wi-Fi calibration live there.

---

## Contributing

Check [Known Issues](docs/Known-Issues.md)
before opening an issue. Issue numbers in commits and scripts refer to the
register in `docs/Known-Issues.md`, not to GitHub issue numbers.

---

## Prior art

- [Azkali](https://github.com/Azkali)'s gts9wifi port — a mainline tree plus the
  firmware payload ([Azkali/gts9wifi-firmware](https://github.com/Azkali/gts9wifi-firmware))
  this port's speaker-protection and VPU staging pulls from.
- [agcarbajo](https://github.com/agcarbajo)'s port — kernel and userspace subsystems.

---

## License

MIT — see [LICENSE](LICENSE). Files under `kernel/` are kernel sources and
carry their own SPDX identifiers (GPL-2.0 for drivers, BSD-3-Clause for device
trees); those identifiers govern those files.
