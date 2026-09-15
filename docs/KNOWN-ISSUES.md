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

**Status 2026-09-15 — implemented, flashed, verified working:**
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