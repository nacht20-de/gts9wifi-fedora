# Known issues (user-reported, not researched)

> **Status tracker.** Reported by the user; intentionally not investigated
> yet. Companion to [PORT-KIT.md](PORT-KIT.md) and [WIFI.md](WIFI.md).

| # | Issue | Details |
|---|---|---|
| 1 | **Battery percentage capped at 96 %** | Charge percentage never reports above 96 % |
| 2 | **No palm rejection** | Palm/hand contact not rejected while using the S Pen — **researched, implemented, flashed, verified working** (see below) |
| 3 | **Bluetooth keyboard connection issues** | Connection errors/drops; noticeably worse while 2.4 GHz Wi-Fi is in use (likely 2.4 GHz coexistence interference) |
| 4 | **No camera** | Camera does not work (no drivers — see also README "What works") |
| 5 | **No rotation sensor** | Screen auto-rotation does not work |

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

## Relevant context already known

- Rotation is related to the SSC sensor stack (accelerometer/rotation vector
  live; see README entry and the pending
  iio-sensor-proxy/libssc fix).
- Camera has no drivers on mainline (README "What works").
- Bluetooth+2.4 GHz coexistence is a common WCN6855-class issue.