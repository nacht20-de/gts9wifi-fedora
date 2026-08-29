# Fedora on the Samsung Galaxy Tab S9 Wi-Fi (gts9wifi, SM-X710)

Fedora userland for the mainline port.  All device knowledge — kernel
patches, DTS, boot chain, firmware — is inherited from the working
postmarketOS port (https://github.com/nacht20-de/pmos-gts9wifi-build);
nothing here duplicates it.  Boot strategy for now: the eMMC chain stays
untouched, Samsung ABL loads the pmOS boot.img and initramfs, which mounts
the SD /boot partition by UUID and switch_roots into whatever ext4 root
carries the matching UUID — so this repo just builds a Fedora rootfs for a
spare microSD with the same two partition UUIDs.  The daily pmOS card is
never touched and the eMMC is never written, apart from the same idempotent
BD-address and carveout DTB patches pmOS itself applies.  Full inventory of
everything extracted from the port and the device: docs/PORT-KIT.md.

Layout:

- `rootfs/` - build-rootfs.sh (runs inside a Fedora aarch64 container),
  overlay/ (device services, mounts, udev rules and UCM translated from the
  pmos port), mk-sd-card.sh (spare-SD assembly), fetch-local-assets.sh.
- `specs/` - RPM specs with the vendored Samsung patches (hexagonrpcd,
  iio-sensor-proxy); compiled inline by build-rootfs.sh for now, COPR later.
- `docs/` - PORT-KIT.md, the extraction inventory.
- `.github/workflows/` - arm64 runner CI, same model as the pmos kernel
  build workflow.

libssc and pd-mapper are not in Fedora and are built from source (libssc
0.4.4, pd-mapper 1.1 — the sm8550 ADSP needs no service-registry JSONs,
verified on the pmOS device).  hexagonrpcd 0.4.0 carries the port's Samsung
sensor-registry patches; iio-sensor-proxy 3.9 builds against libssc.  Device
blobs (firmware payload, kernel modules, boot images, ssh key) are never
committed: rootfs/fetch-local-assets.sh repopulates them from the tablet
and the port kit.

## Building

CI builds a core rootfs: Actions -> "Fedora rootfs" -> Run workflow.  A
first-boot-ready build runs locally with the tablet attached over USB:

    ./rootfs/fetch-local-assets.sh
    podman run --rm -it -v "$PWD:/work:Z" -w /work quay.io/fedora/fedora:44 \
        ./rootfs/build-rootfs.sh
    sudo ./rootfs/mk-sd-card.sh out/gts9wifi-fedora-44-rootfs.tar.gz /dev/sdX

Boot with the spare card inserted; USB networking comes up on usb0:
ssh phablet@172.16.42.1 (phablet / phablet, or the key from local-assets).

## Status

First boot still pending — nothing is verified on hardware yet.  Known
gaps, deliberate for now: the super/vendor erofs mount is disabled (needs
make-dynpart-mappings, a pmOS tool with no Fedora counterpart), SELinux is
permissive, and the rootfs boots the eMMC pmOS kernel 7.2.0-rc3 #121 with
modules injected from the device.  Next: own kernel RPM plus an Android-v4
boot bundle via the pmos repo scripts, then pocketblue-style atomic images
(the ABL kernel-update problem is the open design point there).
