# Fedora on the Samsung Galaxy Tab S9 Wi-Fi (gts9wifi, SM-X710)

Second distribution target for the mainline-Linux port.  Everything hard —
kernel patches, DTS, boot chain, firmware — comes from the working
postmarketOS port ([pmos-gts9wifi-build](https://github.com/nacht20-de/pmos-gts9wifi-build));
this repo packages a Fedora userland around it.  Full extraction inventory:
[docs/PORT-KIT.md](docs/PORT-KIT.md).

## Boot strategy (phase 1)

The eMMC boot chain stays **untouched** — Samsung ABL loads `boot.img`
(kernel `7.2.0-rc3 #121` + appended DTB) + the pmOS initramfs, which mounts
the SD card's `/boot` partition **by UUID**, loads `initramfs-extra`, then
switch_roots into whatever ext4 root carries the matching UUID.  That
initramfs is rootfs-agnostic, so phase 1 simply puts Fedora on a spare SD
card using the same two UUIDs.  Daily pmOS card is never touched.

```
eMMC (unchanged)                 spare microSD (this repo)
┌─────────────────────┐          ┌──────────────────────────┐
│ boot    kernel+DTB  │───┐      │ p1 ext2 /boot            │
│ init_boot ramdisk   │   ├─────▶│   UUID b7869a36-…        │
│ vendor_boot cmdline │───┘      │   known-good boot files  │
│ dtbo (invalid=off)  │          │ p2 ext4 /                │
└─────────────────────┘          │   UUID d2a235a8-…        │
                                 │   Fedora rootfs          │
                                 └──────────────────────────┘
```

## Build

CI (core rootfs, no device blobs):

- Actions → **Fedora rootfs** → Run workflow (arm64 runner, native aarch64
  Fedora container, no qemu — same model as the pmOS kernel workflow).

Local (first-boot-ready, needs the tablet attached via USB):

```sh
./rootfs/fetch-local-assets.sh     # firmware payload, kernel modules, boot files, ssh key
podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 ./rootfs/build-rootfs.sh
sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX
```

First boot: tablet powered off, swap cards, boot.  The pmOS initramfs
brings up USB networking; after switch_root NetworkManager keeps `usb0`
static → `ssh phablet@172.16.42.1` (password `phablet`, or your key via
local-assets).

## What ships in the rootfs

- hexagonrpcd 0.4.0 built from source with the port's two Samsung patches
  (large FastRPC inbufs, sensor-registry writes onto the stock `persist`
  partition) — specs/hexagonrpcd-samsung/
- iio-sensor-proxy 3.9 built with libssc + the slow-discovery patch
- qrtr, pd-mapper, libssc (Fedora repos); bluez with the EFS BD-address
  drop-in
- ALSA UCM for the 4× CS35L45 speaker setup (speaker volume stays capped at
  −19 dB until speaker-protection firmware works — keep it that way)
- Device services translated from the pmOS port: sensor-SSC recovery,
  panel cold-boot recovery, BT address provisioning, rootfs grow
- Runtime mounts of stock Android partitions: `persist` (rw, sensor/Wi-Fi
  calibration) and `dsp`; eMMC partitions are never written except the
  idempotent BD-address DTB patch on `boot`/`vendor_boot`

## Roadmap

- [x] Phase 1 — Fedora rootfs on spare SD, pmOS boot chain, SSH + core
      hardware services (this repo, status: **first boot pending**)
- [ ] Phase 1.5 — vendor `make-dynpart-mappings`, enable `vendor.mount`
      (super → erofs /vendor); python `bt-provision` (per-boot DTB BD patch)
- [ ] Phase 2 — kernel RPM (COPR or Actions-built) + own Android-v4 boot
      bundle via the pmos repo scripts; TWRP-zip/Odin flash flow
- [ ] Phase 3 — pocketblue-style bootc/atomic images (custom `disk.yaml`
      ext2+ext4 without ESP, `artifacts.sh` boot bundle, kernel-update
      story for the ABL chain)

## Not in git (by design)

`local-assets/` — firmware blobs extracted from this specific unit
(Samsung/Qualcomm redistribution caveats), kernel modules, boot images,
your ssh key.  `rootfs/fetch-local-assets.sh` repopulates them from the
device + port kit.
