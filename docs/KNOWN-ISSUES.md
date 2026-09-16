# Known issues (user-reported, not researched)

> **Status tracker.** Reported by the user; intentionally not investigated
> yet. Companion to [PORT-KIT.md](PORT-KIT.md) and [WIFI.md](WIFI.md).

| # | Issue | Details |
|---|---|---|
| 1 | **Battery percentage capped at 96 %** | Charge percentage never reports above 96 % |
| 2 | **No palm rejection** | Palm/hand contact not rejected while using the S Pen — **researched, implemented, flashed, verified working** (see below) |
| 3 | **Bluetooth lag** | Keyboard/audio lag under 2.4 GHz Wi-Fi — **fixed 2026-09-15** (see below) |
| 4 | **No camera** | Camera does not work (no drivers — see also README "What works") |
| 5 | **No rotation sensor** | Screen auto-rotation does not work — **fixed 2026-09-15** (see below) |
| 6 | **USB debug link flaky** | The RNDIS USB gadget stops answering the host's bind handshake after session/suspend churn and won't rebind until replug — **fixed 2026-09-15** (see below) |
| 7 | **Weak 5 GHz Wi-Fi RX** | 5 GHz connects but RX was ~50 dB below physics (-89 dBm vs 2.4 GHz -28 dBm at the same spot; 5 GHz TX healthy). **FIXED 2026-09-15** — LE_X13S BDF substitution restores ~47 dB (5 GHz now -40 dBm); no kernel change. Hardware fault ruled out via Android A/B (5 GHz strong on stock). See below and WIFI.md |

## Palm rejection research (issue 2, 2026-09-14)

**Root cause:** the S Pen digitizer (`wacom-wez01.c`) and touchscreen
(`fts1ba90a.c`) are fully independent input devices. The FTS1BA90A controller
already classifies palm contacts (`FTS_TOUCHTYPE_PALM` BIT5 / `FTS_TTYPE_PALM`),
but the driver reports every accepted touch type (NORMAL/GLOVE/PALM/WET) as a
plain finger, and nothing coordinates the pen's hover state with the
touchscreen.

**Proven mechanism already exists** — the Tab S9 Ultra port
(`ubuntu-galaxy-tab-s9-ultra/kernel/`):
- Wacom driver `samsung_wacom_w90xx.c` tracks pen proximity and exports
  `samsung_wacom_should_suppress_touch()` (`include/linux/samsung_wacom.h`),
  with a **250 ms silence timer** so proximity clears even if the digitizer
  stops sending frames when the pen is lifted.
- Touchscreen calls it at the top of its handler; while the pen is in range it
  releases all finger slots and drops incoming touches — matching Samsung's
  stock palm-rejection behavior.
- Patches: `samsung_wacom_*` export + `suppress-goodix-touch-while-spen-hovering.patch`.
- Kernel-level is required because libinput can only arbitrate touches near the
  pen's last position and gets permanently confused if the digitizer goes
  silent without an out-of-range event.

**Implementation (completed 2026-09-15):**
1. `wacom-wez01.c`: pen-proximity atomic + 250 ms timeout + exported
   `wacom_wez01_should_suppress_touch()`.
2. New header `include/linux/wacom_wez01.h` (inline `false` when driver off),
   installed by `kernel/prepare.sh`.
3. `fts1ba90a.c`: suppression check at the top of the IRQ handler (release all
   slots + drop), plus dropping IC-classified `FTS_TTYPE_PALM` contacts.
4. Kernel rebuilt + boot bundle flashed.

Both devices carry the same swap/invert orientation in the DTS
(`touchscreen-*-x` / `touchscreen-swapped-x-y`), so suppression needs no extra
coordinate handling.

**Status 2026-09-15 — palm rejection implemented, flashed, verified working; S Pen
native resolution fix applied 2026-09-16:**
- `kernel/files/wacom-wez01.{c,h}` and `kernel/files/fts1ba90a.c` updated;
  `kernel/prepare.sh` installs the new header.
- Kernel rebuilt and boot image regenerated from a **fresh `Image.gz`**
  (important: `make` does not repack `Image.gz` by default — always run
  `make Image.gz` after relinking, or the boot bundle silently ships the old
  kernel; caught mid-flash, re-flashed correctly).
- Flashed via TWRP (`adb push` + `dd of=/dev/block/by-name/boot`, which is
  `sda21`); partition readback MD5 verified, and later also directly writable
  from Fedora via `/dev/disk/by-partlabel/boot`.
- On-device check: `T wacom_wez01_should_suppress_touch` + atomics present in
  `/proc/kallsyms`; drivers probe clean, no IRQ storms/errors.
- **User-verified: palm rejection works** (finger touches suppressed while the
  pen is in range; FTS_TYPE_PALM contacts dropped).

**Status 2026-09-16 — S Pen native digitizer resolution fix applied:**
- `kernel/files/wacom-wez01.c` updated: ABS_X/ABS_Y ranges now report the
  full native digitizer grid (0..23603 / 0..14752) at 100 units/mm resolution
  instead of truncating to screen-pixel 2560×1600 (11 units/mm). The
  `#px*2560/(max_x-min_x)` scaling in the IRQ handler is removed; libinput
  uses the physical size and resolution to map pen coordinates to output.
  Fuzz dropped from 4→0 (raw coordinates, no forced smoothing).
- Kernel rebuilt with same recipe as palm-rejection fix, flashed via `dd` to
  `/dev/disk/by-partlabel/boot`; verified on-device via `libinput list-devices`
  (Size: 236×148mm) and direct `EVIOCGABS` readback (`ABS_X 0..23603 res 100,
  ABS_Y 0..14752 res 100`).

**Build recipe (critical — `make clean` before switching toolchains):**
- The tablet's running kernel uses `LLVM=1` with `clang 21.1.8` (not `gcc`).
  Always rebuild with `make ARCH=arm64 LLVM=1`. A gcc build (`CROSS_COMPILE=...`)
  produces an incompatible kernel: different ABI (no CFI), mismatched
  `vermagic` flags, and a stale RELR probe that disables `CONFIG_RELR` (adds
  ~14 MB to the Image from uncompressed relocations). These three together
  cause a **bootloop** because the initramfs and rootfs modules (signed with
  the clang/CFI key) refuse to load.
- Before rebuilding, run `make ARCH=arm64 LLVM=1 clean` to remove any stale
  gcc-built `.o` files, then `make ARCH=arm64 LLVM=1 olddefconfig`.
- Verify after `olddefconfig` that `CONFIG_RELR=y`, `CONFIG_CFI=y`, and
  `CONFIG_CC_IS_CLANG=y` are all present — the LLVM tools (`llvm-nm`,
  `llvm-objcopy`, etc.) must be in `$PATH` (e.g. via symlinks in
  `/usr/local/bin` to the `llvm-21` versioned binaries) for the RELR probe to
  pass.

## Rotation sensor research (issue 5, 2026-09-15)

**Root cause (two independent problems, both fixed):**

1. **Missing udev tag.** Upstream
   `/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules` tags the FastRPC misc
   device `fastrpc-adsp` only `IIO_SENSOR_PROXY_TYPE+="ssc-light ssc-compass"`,
   so `drv-ssc-accel.c` never looks the accelerometer up on the ADSP and
   `HasAccelerometer` stays false.
2. **Claim race in iio-sensor-proxy 3.9.** GNOME (mutter) claims the
   accelerometer within ~15 ms of the proxy owning its D-Bus name —
   `net.hadess.SensorProxy` — but SSC accel discovery takes ~50 ms (registry
   poll + SUID + attribute round-trips). The claim is recorded, polling never
   starts, and the "appeared while already claimed" poll-start only exists in
   the udev-add hotplug path, which never fires for an already-present device.
   The accel therefore reported available but never delivered a measurement.

**Fix (shipped in the rootfs build + in `specs/`):**

- `rootfs/overlay/usr/lib/udev/rules.d/61-gts9wifi-sensor-mount-matrix.rules`
  now appends the `ssc-accel` tag to the FastRPC device (this file sorts
  before `80-iio-sensor-proxy.rules`; both use `+=`).
- `specs/iio-sensor-proxy-libssc/patches/start-polling-claimed-while-starting.patch`
  starts polling any sensor type claimed while the proxy was still setting up
  (right after its `SensorDevice` is opened), so a claim made during discovery
  is honoured instead of lost. Applied together with the existing
  `notify-slow-sensor-discovery.patch` in `rootfs/build-rootfs.sh`.

**Verification:** after a clean rebuild from the pristine 3.9 tarball + both
patches, `monitor-sensor` reports the accelerometer/ALS/compass live (SSC
compass streaming), and **auto-rotate was user-verified on the tablet**
(live orientation `left-up → normal → right-up` while physically rotating).
Mount-matrix quirk from the same udev file maps landscape to `normal`.

## Bluetooth 2.4 GHz coexistence (issue 3, 2026-09-15)

**Symptom:** with Wi-Fi connected on 2.4 GHz, playing audio over a BT
headset made *every* connected BT device lag; the BT keyboard also lagged
occasionally without audio. Never happened on Android.

**Root cause:** the WCN6855 chip (`QCA6490`, 4-wire UART, firmware
`BTFW.HSP.2.1.0-00660`) shares the 2.4 GHz radio between Wi-Fi and BT.
The port's BT stack was otherwise healthy (4-wire flow control muxed on
pins 76-79, correct driver), but the **linux-firmware BT NVM/rampatch is
not tuned for this device's 2.4 GHz coexistence**.  Android runs Samsung's
own device blobs, which is why it never lagged on the same 2.4 GHz band.

A/B proof: with Wi-Fi radio off the lag disappeared entirely; with Wi-Fi
on and the **Samsung** BT firmware the lag was gone too.

**Fix (shipped in the rootfs build):** replace the linux-firmware BT blobs
with Samsung's device ones (extracted read-only from the stock `/vendor`
erofs in `super` via `lpunpack` + `erofs-utils`):

| file in `/usr/lib/firmware/qca/` | content | effect |
|---|---|---|
| `wcnhpnv21g.bin.xz` | Samsung `hpnv21g.bin` NVM (device-tuned power/coex params) | controller now reports `BTFW.HSP_C.2.1.1.c2-00100-PATCHZ-1` |
| `wcnhpbtfw21.tlv.xz` | Samsung `hpbtfw21.tlv` rampatch | same build family as stock |

`rootfs/fetch-local-assets.sh` stages these into
`local-assets/firmware-overrides/usr/lib/firmware/qca/` (only when the
reference device differs from stock), and `rootfs/build-rootfs.sh` applies
`firmware-overrides/` onto the rootfs last so it wins over the
linux-firmware RPM and the firmware payload.  Linux-firmware originals are
kept on the reference device as `*.linuxfw.bak` for rollback.

**User-verified:** with Wi-Fi on (2.4 GHz ch1), headset + keyboard active,
audio and input lag free after the swap.

## USB debug gadget (issue 6, 2026-09-15)

**Symptom:** the USB-C debug link (host reaching the tablet as a network
device) works for a while, then the host's `rndis_host` can no longer bind —
`new_id` / `driver_override` / udev triggers all fail, the interface stays
`NONE`, and only a physical replug (or reboot) rescues it. TWRP's ADB over the
same cable always worked, so hardware/cable were fine.

**Root cause:** the boot image's initramfs pre-creates an **RNDIS** gadget
(`configfs-gadget.g1`, function `rndis.usb0`) before systemd runs. RNDIS
requires a control-plane OID handshake, and on this board that gadget stops
answering it after sustained sessions / suspend cycles; the failed bind prints
a `register`+instant `unregister` in dmesg and no error. Note this is **not
related to the Bluetooth firmware swap** — RNDIS also bound (but with a dead
datapath and ARP timeouts) on the very first install, before any BT work.

**Fix (shipped in the rootfs build):** `gts9wifi-usb-gadget` now **converts
the gadget to ECM** (`usb_f_ecm` / `cdc_ether`) instead of assuming RNDIS: it
unlinks the UDC, removes any `rndis.usb0` function left by the initramfs,
links `ecm.usb0`, rebinds the UDC, and forces `172.16.42.1/24` on `usb0`.
`cdc_ether` is class-matched (02/06/00) with no OID handshake, so the host
auto-binds as `enx<hostmac>` on enumeration and survives replug/suspend.

Usage from the host: bind is automatic; then `sudo ip addr add 172.16.42.2/24
dev enx...` and `ssh fedora@172.16.42.1`. Original RNDIS script kept on the
device as `gts9wifi-usb-gadget.rndis.bak`.

**User-verified:** SSH over `172.16.42.1` via `cdc_ether` works (~0.4 ms), a
fresh ECM re-enumeration binds immediately, and the conversion persists across
a reboot.

## Weak 5 GHz Wi-Fi RX (issue 7, 2026-09-15)

**Symptom:** 5 GHz associates (`wpa_state=COMPLETED`) but the link is
effectively unusable: RX sits at **-89 dBm / 13.5 MBit/s (VHT-MCS0 40MHz
NSS1)** while 2.4 GHz on the same router shows **-28 dBm / 52 MBit/s**. 5 GHz
**TX** is fine (**351 MBit/s VHT-MCS4 80MHz NSS2**), so the deficit is a pure
receive-path weakness (~50 dB below free-space prediction, confirmed at ~5 cm
range: -72…-85 dBm vs -23 dBm on 2.4 GHz).

**Exhaustive search (docs/WIFI.md has the full detail):**

- All 8 Samsung BDF variants (`bdwlan/…bdwlang`) tested as `board.bin` →
  no effect, because **board-2.bin's exact ABI match**
  (`subsystem-device=0108`) always wins and loads the *generic* 60,036 B BDF
  (md5 `0e92fa42`).
- Samsung BDFs **injected** as the matched payload in a custom board-2.bin →
  firmware crash (`failed to load board data file: -2` + `MHI_CB_EE_RDDM`).
  Control: same custom container + generic payload boots fine → the Samsung
  BDF *content* is incompatible with the mainline IOE firmware.
- Samsung's non-LITE `amss20` firmware family also crashes mainline ath11k.

**Conclusion:** on mainline Linux there is no way to feed the device-specific
5 GHz RX calibration. Every bootable combination shows the same weak 5 GHz RX.
The 2.4 GHz band and 5 GHz TX are healthy, so the radio/antenna chain itself
works — the exact RX-path parameter lives in data that cannot be loaded.

**Internet research (2026-09-15, full write-up in docs/WIFI.md):** the
symptom signature (weak 5 GHz RX, near-field OK, 2.4 GHz fine) matches the
well-known **BDF template-version / mismatched-board-file** failure mode
("weak signal, bad noise values; 5G clients only connect from ~20 cm").
The tablet loads a *generic reference-design* BDF (`subsystem-device=0108`,
`qmi-board-id=255` — Qualcomm reference ID, no variant), not a Samsung-tuned
one; Samsung's own BDFs are an older template the IOE firmware rejects. Since
`variant` cannot be used on WCN6855 M.2 boards, most such devices run the
generic BDF. **Promising, untested fix path:** *BDF substitution* — remap a
different vendor's compatible board file (e.g. the HP_G8_Lancia14 data used
for HP Omnibook hw2.1) into our slot via `ath11k-bdencoder` and measure 5 GHz
RX; precedents for this working exist on the ath11k list.

**Android A/B test (2026-09-15) — hardware ruled out:** stock Samsung Android
was booted at the same position (Linux backed up; boot chain re-flashed; then
fully restored, md5-verified). 5 GHz was **strong on Android** at both the
2–3 m and near-field spots. Same radio + antennas + position ⇒ the 5 GHz
receive chain is healthy; the ~50 dB RX deficit is introduced by the Linux
(ath11k + IOE firmware + generic BDF) combination — a firmware/software RX
tuning mismatch, not a hardware fault. Prime suspect: the generic BDF / IOE
firmware pair missing the device-specific 5 GHz RX gain/antenna config, or an
ath11k RX-path quirk on hw2.1.

**FIXED 2026-09-15 — BDF substitution with the LE_X13S board file works:**

The generic 60,036 B matched payload (md5 `0e92fa42`) was swapped for the
**Lenovo Snapdragon X13s** board file (LE_X13S / NTM_TW220, md5 `6d42746b`,
60,008 B — same `subsystem-device=0108` / chip-id 18 Qualcomm reference
subsystem, device-tuned) inside the board-2.bin container using `bdftool.py`
(custom Python re-implementation of `ath11k-bdencoder`). Measured at the same
2–3 m spot, on the same AP/firmware, with a reload+restore control between
(scripts: `/tmp/opencode/bdf-test/bdftool.py`, `test-bdf.sh`):

| board-2.bin payload | 5 GHz (5180 MHz) RSSI |
|---|---|
| generic (control) | -86 … -87 dBm |
| **LE_X13S** | **-39 … -40 dBm** |
| restore generic (control) | **-87 dBm** (reproducible) |

~47 dB 5 GHz RX recovery. End-to-end re-check on ch36: `signal avg -45 dBm`,
`beacon signal avg -43 dBm`, `authorized/associated yes`, 2.4 GHz unchanged
(-28 dBm). AES: the same measurement chain that reported -87 for the generic
BDF reports -40 for LE_X13S with no other change ⇒ causal. Persisted on the
tablet (`board-2.bin` md5 `872764e4`; generic backed up to
`board-2.bin.generic-bak`) and staged in
`local-assets/firmware-overrides/usr/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin`
(fetched automatically by `rootfs/fetch-local-assets.sh`) so rootfs rebuilds
carry the fix.

**Status:** **resolved 2026-09-15** — 5 GHz RX restored (~47 dB) via LE_X13S
BDF substitution; no kernel change needed.