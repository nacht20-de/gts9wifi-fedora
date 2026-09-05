# gts9wifi Fedora port kit

> **Internal development notes.** This is the extraction inventory behind
> the port, kept for porting and debugging — it is not end-user
> documentation. For installing, see [INSTALL.md](../INSTALL.md); for the
> overview and hardware status, the [README](../README.md).

Everything extracted from the working device port and the live device
(`phablet@172.16.42.1` over USB network), assembled for a Fedora-style port. Captured 2026-08-29, device running
`7.2.0-rc3 #121-samsung-gts9wifi-mainline`.

## Kit layout

| Path | Contents |
|---|---|
| `emmc-boot-images/` | Raw dumps of the five eMMC boot-chain partitions (the proven-booting bytes) |
| `known-good-sd-boot/` | The SD card `/boot` contents (vmlinuz, initramfs(+extra), DTB, boot/vendor_boot.img, config, System.map) |
| `device-pkg.tar.gz` + `device-pkg/` | Installed `device-samsung-gts9wifi` package payload (38 files: all services, scripts, udev rules, UCM, mounts) |
| `live-state/` | `proc-cmdline.txt`, `apk-world.txt`, `lsblk.txt`, `partitions-and-issues.txt` (full by-partlabel map) |
| `../firmware-extract/` | `firmware-samsung-gts9wifi` payload (24 MB, 260 files) + `FILELIST.txt` manifest |

## Boot architecture (verified on this device)

Samsung ABL (X710) loads, per Android boot-image v4:

| Partition | eMMC | Size | Role |
|---|---|---|---|
| `boot` | sda21 | 96M | `ANDROID!` header v4, kernel Image + **appended mainline DTB** |
| `init_boot` | sda22 | 8M | generic ramdisk (lz4-legacy); too small for a real initramfs, so the bundle ships an empty cpio and the full initramfs rides in vendor_boot |
| `vendor_boot` | sda24 | 96M | `VNDRBOOT` header, vendor ramdisk + **cmdline + bootconfig**; its DTB is the one ABL actually loads (verified on the live FDT 2026-09-04) |
| `dtbo` | sda30 | 16M | **deliberately invalid (all zeros)** → forces ABL's DeviceTreeAppended fallback |
| `vbmeta` | sde15 | 128K | **zeroed** (verified boot disabled, flags 2; read-only in TWRP) |
| `vbmeta_system` | sda18 | 64K | `AVB0` header, hash footers added by `avbtool add_hash_footer` |

Sizes for `init_boot` and `vbmeta` re-verified from TWRP `blockdev
--getsize64` on 2026-09-04; the original 2026-08-29 capture mis-recorded
them as 96M/4M.

Pagesize 4096. The bundle that produces these is
the original port's `scripts/build-android-v4-bundle.sh` + `bundle-inputs/` — **fully
distro-agnostic**, reusable for Fedora with only the vendor_boot cmdline changed.

### Rootfs: external microSD (how this device actually runs)

- SD: `mmcblk1p1` = 487M ext2 `/boot` (UUID `b7869a36-d9a0-4403-b9fd-e0ebec016b76`),
  `mmcblk1p2` = ext4 `/` (UUID `d2a235a8-37cd-4bac-be53-16caf2bfdd21`, partlabel `primary`).
  Physical SD = **512-byte logical sectors** (deviceinfo explicitly warns about this vs UFS 4K).
- Flow: eMMC boot.img kernel + embedded initramfs → mounts SD p1 **by UUID** read-only →
  loads `initramfs-extra` (full modules) → mounts p2 root.
- **eMMC is authoritative**: the SD `/boot` copy is stale (Aug 10) vs the flashed
  kernel (#121, Aug 22). Kernel updates happen by reflashing eMMC from CI artifacts,
  not by the SD copy.
- Stock Android eMMC partitions are all still intact (`userdata` = sda34, `super` = sda25, …).

### Cmdline (live, `live-state/proc-cmdline.txt`)

Console + `clk/pd/regulator_ignore_unused`, `rootwait`, `mem_sleep_default=s2idle`
(**deep suspend resets the SoC**), panel override `msm_drm.dsi_display0=GTS9_ANA38407_AMSA10FA01`
+ ~40 Samsung downstream module params (carried from stock cmdline; most are no-ops on mainline).

## Runtime dependencies on stock Android partitions (critical for Fedora design)

The working system **mounts Android partitions at runtime** — this is not
first-boot extraction:

- `gts9wifi-android-parts.service` → `make-dynpart-mappings /dev/disk/by-partlabel/super`
  (dm-linear mapping of dynamic partitions) → `/dev/mapper/vendor`
- `vendor.mount`: super/vendor **erofs** → `/vendor` (read-only)
- `vendor-dsp.mount`: partlabel `dsp` (sda16, ext4) → `/vendor/dsp`
- `mnt-vendor-persist.mount`: partlabel `persist` (sda5) → `/mnt/vendor/persist`
  **read-write** — Samsung sensor registry writes (patched hexagonrpcd) + Wi-Fi calibration live here
- `gts9wifi-bt-provision`: reads BD address from partlabel `efs` (sda6) and patches
  `local-bd-address` into the DTB **inside the eMMC boot and vendor_boot images, every
  boot** (idempotent; survives reflashes)

Consequence: pocketblue's `droid-juicer` (copy-firmware-once) does **not** cover this
device — persist needs a permanent RW mount and super/vendor need live mapping.
`make-dynpart-mappings` has no Fedora equivalent yet (small tool; worst case: port it,
or replicate the devicekit approach).

## Kernel (converts to RPM)

Source of truth: `pmaports/device/testing/linux-samsung-gts9wifi-mainline/`.
Mainline 7.2-rc3 + 20 patches/ODMs: `fts1ba90a.c` (touch), `panel-samsung-ana38407.c`,
`sm5714_battery.c` / `sm5714_usbpd.c` / `sm5440_direct.c` / `ps5169.c` / `wacom-wez01.c`,
plus fixes (eUSB2 phy init, PTN3222-from-DT, WCN pwrseq cold-reset+AOP PDC, DP bridge,
TCPM roles, PCIe0 pipe mux, sec-log console, split-GPU-KMS). DTS:
`sm8550-samsung-gts9wifi.dts`. Config fragment builds in MMC/SDHCI-MSM/EXT4/INITRD (=y)
— an initramfs-less boot is possible, but Fedora/bootc dracut flow expects initramfs.

## Userspace inventory (what must exist on Fedora)

- **hexagonrpcd 0.4.0** pinned with 2 custom patches: `hexagonrpc-large-inbufs.patch`,
  `support-samsung-sensor-registry-writes.patch` (+ Alpine's systemd-services patch).
  Fedora's `hexagonrpc` package does **not** carry these → build in COPR. Enabled units:
  `hexagonrpcd-sdsp`, `hexagonrpcd-adsp-rootpd`, `hexagonrpcd-adsp-sensorspd`.
- **iio-sensor-proxy 3.9** built **with libssc** + `notify-slow-sensor-discovery.patch`
  (verify Fedora's build has libssc; else COPR).
- **pd-mapper** (in Fedora), qrtr/tqftpserv infra (Fedora), rmtfs not used here
  (rootfs on SD, not modem storage).
- Audio: UCM `Samsung-Galaxy-Tab-S9.conf` + `HiFi.conf` (4× CS35L45 on PRIMARY MI2S,
  no WSA/WCD; volume capped at 380/-19 dB because Cirrus speaker-protection DSP is
  **not loaded** — keep the cap). AudioReach topology in firmware payload.
- Optional polish (Alpine-forked, would need RPM porting): mutter 50.2 (accelerometer
  reclaim on new SensorProxy owner), gnome-control-center, xorg-server patches.

### Hardware workarounds encoded in the device package (all under `device-pkg/`)

- `panel-coldboot-recover`: runs a `pm_test=platform` suspend cycle to revive the
  ANA38407 DDIC after Samsung's cold-boot handoff
- `panel-reinit` + `display-wake` + `display-handoff`: DRM off/on cycle after warm
  reboots; Mutter PowerSaveMode revival after lid wake
- `sensors-resume` (+ system-sleep hook): restart sensorspd + iio-sensor-proxy after
  every resume (libssc can't reconnect a stale QMI client)
- `bt-revive`: rebind hci_uart_qca holding BT_EN (tlmm gpio 204) via gpio cdev
- `bookcover-input`: fixes Samsung Book Cover Keyboard HID descriptor (python evdev)
- `adsp-boot`: late ADSP start — **disabled by default** (can hang/reset the SoC)
- udev: sensor mount-matrix, devfreq perms, Logitech Lightspeed
- systemd conf drops: journal caps, fbdev, display hold, lid, SDDM, VM tuning

## Pocketblue mapping (from the structural analysis)

Reusable as-is: whole container pipeline (Containerfile layers, common/desktop/device
`build` scripts, rechunk/chunkah, cosign, GH Actions on `ubuntu-*-arm` runners), kernel
RPM-swap pattern, Qualcomm service enablement, zram/grow-rootfs (grow-rootfs works on
ext4 SD root).

Must be replaced for this device:

1. **`disk.yaml`**: ext2 `/boot` + ext4 `/` (no ESP, no U-Boot) — image-builder supports
   arbitrary layouts; note `postprocess.sh` hardcodes p1=ESP/p2=root and 4096 sectors.
2. **`split_partitions=false`** + custom `artifacts.sh` that runs the repo's
   `build-android-v4-bundle.sh` to emit boot/init_boot/vendor_boot/dtbo/vbmeta with a
   Fedora `root=UUID=<SD p2>` cmdline in `bundle-inputs/vendor_boot/cmdline.txt`.
3. **bootc kargs don't reach ABL** — the kernel cmdline lives in vendor_boot. Kernel
   updates therefore need a boot.img rebuild+reflash step (CI artifact, or an on-device
   unit à la `bt-provision`). This is the main open design point for the atomic variant;
   a non-atomic image avoids it.
4. Firmware RPM from `../firmware-extract/payload` (nabu-style `*-firmware` package)
   **plus** the runtime Android-partition mounts above.

## Checksums (eMMC dumps)

```
250ac4d02a2e2bf21dc5a60b7aa17435  emmc-boot-images/recovery.img   (sda23, 109576192)
9565bb89f7b157de91edf512366c27ce  emmc-boot-images/boot.img       (sda21, 100663296)
d4b96c8bc3ce1f1f0fb5126d7e2c6525  emmc-boot-images/vendor_boot.img(sda24, 100663296)
c485a63a08c4b6708c397878c5e6d35e  emmc-boot-images/dtbo.img       (sda30, 16777216)
a26daf3454a40d570e0696ff681a89ab  emmc-boot-images/vbmeta_system.img (sda18, 65536)
```

## Live issues observed during extraction (2026-08-29)

- `gts9wifi-wait-sensor-proxy.service` **failed this boot** (exit 5 — SSC did not
  report an accelerometer within ~90 s). Sensors currently down on the device until
  the resume script or a reboot recovers it.
- systemd timestamps show 1970-01-05 for early-boot units — RTC has no valid time
  before NTP sync (no RTC battery path in the port).
