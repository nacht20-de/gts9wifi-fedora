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

Booted on hardware (2026-09-04): the eMMC now carries this repo's own boot
bundle (kernel 7.2.0-rc3-gts9wifi) with the SD-card Fedora root.  Wi-Fi
(QCA6490/ath11k) and BT (hci_uart QCA) come up from a cold start: the DTS
programs the stock X710 AOP wlan_pdc table over the QMP mailbox (the pmOS
port dropped it as kiwi-specific; a cold handoff disproves that - without
the votes the WCN PMU never completes power-up, PCIe enumerates after the
bus scan and the BT ROM never answers).  When flashing a new boot bundle,
ALWAYS install the matching kernel RPM on the rootfs afterwards: each CI
run signs modules with a fresh ephemeral key, so a new boot.img with the
old module tree fails with "Operation not permitted".  Sensors (accel/
light via the SSC) are dead, same as on pmOS.  Known gaps: super/vendor
erofs mount disabled (needs make-dynpart-mappings), SELinux permissive,
Bluetooth hci0 completes kernel setup but never registers with bluez mgmt
("Index list with 0 items") - open issue.
