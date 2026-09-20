# Hardware Notes

Per-subsystem notes for this device: what the hardware is, what the port's
driver does, and the traps hit while bringing it up. Bus and address details
are included because they are tedious to rediscover.

---

## Display

| Item | Value |
|---|---|
| Panel | 2560×1600 AMOLED, DSI + DSC |
| Panel driver | `panel-samsung-ana38407.c` (out-of-tree) |
| DDIC | ANA38407 |

A cold boot from the bootloader does not leave the DDIC in a state mainline can
take over, so the port ships a cold-boot revive service that runs a
`pm_test=platform` suspend cycle automatically at boot; without it the panel
stays dark on a cold start. Warm paths have two related workarounds: a DRM
off/on reinit cycle after warm reboots, and a Mutter PowerSaveMode revival
after lid wake. "Works on reboot but not on cold start" (or the reverse) means
panel handoff state, not the DRM driver.

---

## Touchscreen

| Item | Value |
|---|---|
| Controller | FTS1BA90A, 1600 × 2560 panel |
| Bus / address | device-tree `&i2c4` (`a90000.i2c` behind `ac0000.geniqup`) → i2c-10 at `0x49` |
| Interrupt | IRQ 189 = TLMM GPIO 25, `IRQ_TYPE_LEVEL_LOW` |
| Rails | `avdd` = 3.3 V, `vddio` = 1.8 V |
| Driver | `kernel/files/fts1ba90a.c` — a minimal rewrite, not a vendor port |

The driver speaks the FTS register protocol directly and declares multi-touch
(`ABS_MT_POSITION_X/Y`, `TOUCH_MAJOR/MINOR`, `PRESSURE`), with
`touchscreen-inverted-x` and `touchscreen-swapped-x-y` in the DT.

The original driver had no wake support at all: its suspend path disabled the
IRQ and powered off both rails, with no `device_init_wakeup()`, no
`enable_irq_wake()`, no `KEY_WAKEUP` and no `wakeup-source` property — the
touchscreen never appeared in `/sys/kernel/debug/wakeup_sources` and a tap
while suspended could not be seen. Double-tap-to-wake is not possible without
the driver declaring itself a wake source and keeping the rails alive across
suspend; no userspace setting can add it.

### Double-tap-to-wake

The fix arms the stock gesture (sponge mode, plus two register writes), keeps
the rails on and enables the IRQ as a wake source, reports `KEY_WAKEUP`, and
registers as a wake source. Verified: a suspend entry was ended by a tap after
12.7 s of sleep, while the 150 s RTC fallback never fired.

The UI is a GNOME Shell extension settings page talking to a device-control
helper; the choice is stored under `/var/lib/gts9wifi/` and re-applied at boot
by a systemd unit, and a udev rule makes the touchscreen attribute
group-writable so the session needs no privileges. There is no Quick Settings
toggle by design.

GNOME Shell does not rescan extension directories at runtime, so the extension
is only discovered at session start. The earlier "screen stays dark after a
gesture wake" report was a broken resume path, not a DT2W defect.

---

## S Pen digitizer

| Item | Value |
|---|---|
| Driver | `kernel/files/wacom-wez01.c` (out-of-tree) |

Works. The native digitizer resolution was wrong and is fixed (100 units/mm);
the tilt sensor is still missing.

Palm rejection is kernel-level. The digitizer and the touchscreen are fully
independent input devices; the touchscreen controller already classifies palm
contacts, but the driver reported every accepted touch type
(normal/glove/palm/wet) as a plain finger, and nothing coordinated the pen's
hover state with the touchscreen. The fix tracks pen proximity and exposes a
"should suppress touch" query with a 250 ms silence timer, so proximity clears
even if the digitizer stops sending frames when the pen is lifted. While the
pen is in range, the touchscreen releases all finger slots and drops incoming
touches. Userspace arbitration cannot do this: it can only reason about
touches near the pen's last position and gets permanently confused if the pen
is not seen at all.

---

## Sensors (SSC)

| Item | Value |
|---|---|
| Path | Qualcomm SSC on the ADSP |
| Daemon | `hexagonrpcd` 0.4.0, with two port patches |
| Desktop | `iio-sensor-proxy` built with libssc |
| Exposed | accelerometer, rotation vector, ambient light, compass |

The sensors live behind the ADSP's sensor core, not on an AP I2C bus. The port
runs `hexagonrpcd` (sdsp, adsp-rootpd, adsp-sensorspd) and a patched
`iio-sensor-proxy`; ambient light and compass are served over D-Bus, and screen
auto-rotate works.

- libssc cannot reconnect a stale QMI client, so `hexagonrpcd-adsp-sensorspd`
  and `iio-sensor-proxy` are restarted by a system-sleep hook on every wake.
  Without it, sensors are dead for the rest of the session after the first
  suspend.
- systemd 259 never reads `/etc/systemd/system-sleep/`; the hook must live in
  `/usr/lib/systemd/system-sleep/` or it is silently inert.
- The restart conflicts with `suspend.target`. A queued but unexecuted job
  leaves the unit reading `inactive`, so waiting on `ActiveState` returns
  immediately and restarts happen too early — wait on `systemctl list-jobs`.

Sensor rotation is not observable from the sensor values; orientation is
verified by eye, and the mapping does not necessarily match the vendor's
property names.

---

## Wi-Fi

| Item | Value |
|---|---|
| SoC | Qualcomm WCN6855 (reports as `QCA6490`) |
| Driver | `ath11k_pci`, hw_params reports hw2.1 |
| Firmware | `amss.bin` + `m3.bin`, IOE family |
| Board data | `board-2.bin` in `/lib/firmware/ath11k/WCN6855/hw2.1/` |
| Regulatory | wiphy is self-managed — the firmware decides channel flags |

### Firmware family matters more than version

Samsung's own non-LITE `amss20` image crashes ath11k with `MHI_CB_EE_RDDM`.
The image that runs is the mainline-friendly IOE family, paired with a
matching IOE `m3.bin`. The firmware family matters, not just the file name.

### `board.bin` swaps are a no-op

`board-2.bin` has an exact ABI match for this tablet
(`bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,
qmi-chip-id=18,qmi-board-id=255`), so the matched payload inside `board-2.bin`
is loaded and `board.bin` is ignored entirely. All eight vendor `board.bin`
variants were tested and produced identical behaviour. If board-data changes
have no effect, check whether `board-2.bin` is matching the device first;
injecting into the container is the only thing that works.

### The vendor BDF can be worse than a generic one

Injecting Samsung's BDF payload made ath11k fail with
`failed to load board data file: -2` followed by a firmware crash — the
mainline IOE firmware rejects the vendor BDF content. A custom container
carrying the generic payload boots fine, so the container format was valid and
the vendor content was the problem.

The 5 GHz RX weakness was fixed by substituting a different device's BDF
payload (LE_X13S) into this device's exact-ABI slot inside a custom
`board-2.bin` — roughly a 47 dB improvement. The vendor file is not
automatically the best file.

### Cold start and regulatory

- Cold start is fixed by the AOP PDC init table in the device tree. Wi-Fi and
  Bluetooth power up through the WCN sequencer; without the init table the
  first cold boot after flashing does not bring the chip up.
- The wiphy is self-managed, so the firmware rather than cfg80211 decides
  channel flags. Getting 5 GHz channels usable required
  `CONFIG_CFG80211_CERTIFICATION_ONUS`,
  `CONFIG_ATH_REG_DYNAMIC_USER_REG_HINTS`,
  `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n`, an embedded `regulatory.db`, and
  lockdown disabled — plus a patch that only applies `NO_IR` when a rule also
  carries `REGULATORY_CHAN_RADAR`, which frees non-DFS 5 GHz while keeping it
  on DFS channels. After that, channel 36 reports active at 20 dBm.

Three plausible causes of the 5 GHz failure were ruled out before the BDF was
identified. A test network's SSID and BSSID are deliberately not recorded.

---

## Bluetooth

| Item | Value |
|---|---|
| Driver | `hci_uart_qca` |
| Enable line | `BT_EN` = TLMM GPIO 204 |
| Address source | the `efs` partition |

- BD address provisioning patches the boot images, not a config file. A
  service reads the address from the `efs` partition and patches
  `local-bd-address` into the DTBs inside the `boot` and `vendor_boot` images
  on every boot. It is idempotent and survives reflashes, but the address
  applies from the second boot after flashing a new bundle — the "Bluetooth
  needs one extra reboot" note in [Installation](../INSTALL.md).
- `bt-revive` rebinds `hci_uart_qca` while holding `BT_EN` through the gpio
  character device, for when the chip comes up in a bad state.
- 2.4 GHz coexistence was fixed by substituting Samsung's device-tuned
  NVM/rampatch for the generic ones, which keeps a BT keyboard and audio
  lag-free while 2.4 GHz Wi-Fi is active.

---

## Audio

| Item | Value |
|---|---|
| Amplifiers | 4× Cirrus CS35L45 on PRIMARY MI2S |
| Codec | none of the usual WSA/WCD path |
| Config | ALSA UCM (`Samsung-Galaxy-Tab-S9.conf` + `HiFi.conf`) |
| Protection FW | `cirrus/cs35l45-dsp1-spk-prot.{wmfw,bin}` |
| Topology | AudioReach, in the firmware payload |

`linux-firmware` ships no CS35L45 blobs at all. Without the speaker-protection
DSP firmware the limiter does not bound cone excursion, so the per-amp volume
had to stay far below full scale; once the firmware loads, the volume can be
raised about 12 dB. Do not raise it before the protection firmware actually
loads — the limiter is what makes the extra headroom safe. The build treats a
failure to fetch that firmware as fatal, because the silent alternative is an
unprotected speaker.

Two subtleties:

- The protection and characterisation files are not duplicates — they carry
  different deploy groups (tuning versus speaker characterisation). Mainline's
  `wm_adsp` loads exactly one `.bin` per DSP, so the characterisation group is
  never applied. That is why 7.25 dB is deliberately held back below full
  scale: the limiter runs on nominal rather than measured speaker parameters.
- A firmware payload can carry files that nothing loads. Verify with `dmesg`
  that the DSP firmware actually loaded, per amplifier.

---

## Battery and charging

| Block | Address | Bus | Driver |
|---|---|---|---|
| SM5714 charger | `0x49` | `i2c-6` | `sm5714_battery.c` |
| SM5714 fuel gauge | `0x71` | `i2c-6` | `sm5714_battery.c` |
| SM5714 MUIC | `0x25` | `i2c-6` | `sm5714_battery.c` |
| SM5714 USB-PD / TCPM | `0x33` | `i2c-7` | `sm5714_usbpd.c` |
| SM5440 direct charger | `0x63` | `i2c-4` | `sm5440_direct.c` |

Pack: EB-BX916ABY, 8160 mAh, 4.44 V max.

The port drives the charger directly. The usual Qualcomm `pmic_glink`/
`qcom_battmgr` path needs a `charger_pd` domain that this device's ADSP
firmware does not expose, so `sm5714_battery.c` talks to the chip itself.

### The 96 % cap was undercharging

Not a gauge bug: the charger's float voltage was never programmed, so the pack
charged 60 mV short of full. The register is `CHGCNTL4` (`0x1a`), bits `[5:0]`;
the port programs it from `voltage-max-design-microvolt` — at probe and again
inside `configure_charging()`, because the charger block loses its programming
when the cable is out long enough for the chip to power-cycle.

### The gauge is a closed model

Read through a window at the gauge address: write the word offset to `0x8c`
(`RADDR`), read `0x8d` (`RDATA`), little-endian. Word `0x00` is state of charge
as unsigned Q8.8, so `25600` = 100.00 %.

```
i2cset -f -y 6 0x71 0x8c 0x00 w && i2cget -f -y 6 0x71 0x8d w
```

Stock does more than read it. Samsung's stack programs the gauge from a
`battery_params` DT node (battery model tables, `rs_value`, `i_cal`, `v_cal`)
and anchors the reported capacity with a learned `capacity_max`. It also lowers
the float voltage as the cell ages (4440 → 4420 → 4400 → 4380 → 4330 mV over
the cycle-count buckets). The port does none of that: it reports the gauge's
own SOC directly and programs a flat 4440 mV, and it exposes no `cycle_count`,
so the aging profile cannot be matched. That is the gap to stock-equivalent
behaviour.

### Charging bypass is a userspace gap

The hardware and stock support exist (`battery,ovp_bypass_mode` plus two
register writes) and the kernel already has a `Bypass` charge type, but neither
UPower 1.91.4 nor GNOME 50.4 exposes a bypass control — it needs a desktop
patch, on the standard `charge_types` API rather than a device-private knob.

---

## Cameras

| Item | Value |
|---|---|
| Rear sensor | SK Hynix HI1337 13 MP (4128×3096), I2C `0x21`, CCI0 bus 1 |
| Rear lens | DW9808 VCM, I2C `0x0c`, CCI1 bus 0 — manual focus only |
| Front sensor | SK Hynix HI1337 12 MP (3408×2556), I2C `0x21`, CCI1 bus 1 |
| Raw format | `V4L2_PIX_FMT_SGRBG10P` (10-bit packed Bayer GRBG), stride 5168 |

A failing probe blocks the whole camera stack: a sensor whose probe fails
blocks the camss async notifier, and `v4l2_device_register_subdev_nodes()` only
runs in the notifier's complete callback — so no `/dev/v4l-subdev*` existed at
all and the working rear camera disappeared too. If a whole camera stack
vanishes rather than one camera, look for one device failing to probe.

The front camera's bug was the I2C address: the port had inherited the module
EEPROM's address (`0x20`, from stock's `slaveAddress 0x40 >> 1`) instead of the
sensor's (`0x21`). The symptom sequence was misleading — first
`-ENXIO: invalid CSI-2 endpoint` (a driver-level check, never reaching
hardware), then a real I2C NAK at the EEPROM's address.

### In-DT address sweep

A throwaway device tree with one node per 7-bit address from `0x08` to `0x77`,
each carrying its own `reg`, its own CSI-2 endpoint and the same supplies,
clocks and GPIOs, settled it in a single reboot. The i2c core probes them
sequentially, so each probe runs the driver's real power-up — rails, enable
GPIO, reset release, MCLK — and then reads the identity registers at that
address. Only one answered.

This finds what `i2cdetect` cannot: userspace I2C cannot enable the sensor's
MCLK or sequence its LDO, so a userspace scan of an unclocked sensor finds
nothing at any address. Two practical notes: the extra nodes must be slimmed
to fit the fixed-size `vendor_boot` DTB slot (drop `status`,
`assigned-clocks`, `pinctrl-1`, `orientation`/`rotation` — each is inherited
from the real node that probes first), and the DTS `__symbols__` node has to
go to make room.

### Orientation

The sensor's `rotation` must be 0 for both cameras. Stock's
`sensor-position-roll` (rear 90, front 270) does not map onto V4L2's `rotation`
on this stack, and reasoning from libcamera's counter-rotation convention
produced the wrong answer. The raw stream is byte-identical for any value, so
no `v4l2-ctl` capture can reveal a wrong rotation — it only shows up in an
application's viewfinder and must be verified by eye.

### Other camera facts

- Both sensors share the same CSI/VFE path, so front and rear are mutually
  exclusive at the V4L2 level — one at a time.
- There is no autofocus anywhere in this stack: no layer implements an AF
  loop, and libcamera has no lens control for this combination. A fixed focus
  of 384 ships instead.
- libcamera needed a sensor helper for this part; without it automatic gain
  control never ran and images came out at maximum gain.
- GNOME Snapshot is the recommended viewer.

---

## GPU

| Item | Value |
|---|---|
| GPU | Adreno 740 |
| Kernel | mainline `msm_dpu`, not Qualcomm's KGSL |
| GL | Mesa freedreno (`msm_dri.so`) |
| Vulkan | Mesa Turnip (`libvulkan_freedreno.so`) |

The GPU firmware has to be in the initramfs. The Samsung-signed zap shader
plus `a740_sqe.fw` and `gmu_gen70200.bin` are dracut `install_items`, because
the GPU probes before the root filesystem is up. The device tree's
`zap-shader` node names `qcom/a740_zap.mdt` with the split `.b00`/`.b01`/
`.b02` form, while some sources publish a single `.mbn` — check which form the
loader expects.

There is no proprietary Qualcomm GPU driver to switch away from on this
device: the kernel driver is mainline and both GL and Vulkan are Mesa.

Turnip does not implement Vulkan Video decode. The `VK_KHR_video_*` strings
appear exactly once in every Mesa Vulkan driver, including the software
rasteriser — they come from an alphabetised extension-name registry table, so
their presence is not evidence of support.

---

## Hardware video decode

| Item | Value |
|---|---|
| Block | Qualcomm iris VPU 3.0 |
| Kernel driver | mainline `qcom-iris` (GPL-2.0-only), bound at `aa00000.video-codec` |
| Decoder | `/dev/video17` — stateful V4L2 M2M MPLANE, no stateless capability |
| Encoder | `/dev/video18` — untested |
| Firmware | `qcom/vpu/vpu30_4v.mbn`, Samsung-signed |

The driver was already in mainline and already correct: the DTS and driver
worked and `/dev/video17` registered, but the firmware load failed with
`ENOENT` and the driver logs nothing at probe. `linux-firmware` ships a
`vpu30_*_s*` family but not this one, and the CI firmware payload did not
carry it either. Verify the exact blob name the device requests.

The firmware loads on the first `open()` of `/dev/video17`, not at probe — so
the fix needed no kernel rebuild and no reboot, and "the driver loaded and
logged nothing" is not evidence the firmware is present. The driver only logs
on error.

Firmware is placed in reserved memory and authenticated with PAS, so a generic
blob is useless: it has to be the vendor-signed one, staged with a pinned
checksum that fails the build. A silent fallback means a device that boots and
quietly decodes in software.

### Which applications can use it

The VPU is reachable only as a stateful V4L2 M2M device, and there is no
VA-API driver for it. Whether a program can use the hardware depends entirely
on which decode API it speaks:

| Program | Reaches the VPU? | Why |
|---|---|---|
| `ffmpeg` (`*_v4l2m2m`) | yes | speaks V4L2 M2M directly |
| mpv `--hwdec=v4l2m2m-copy` | yes | FFmpeg's V4L2 M2M decoder |
| GStreamer (`v4l2h264dec`) | yes | stateful M2M decoder |
| Epiphany (WebKitGTK → GStreamer) | yes | inherits the GStreamer path |
| VLC | no | only VA-API and VDPAU; no V4L2 M2M decoder at all |
| Firefox | no | attempts VA-API, finds no driver |
| Chromium / Vivaldi | no | VA-API compiled in but fails; no stateful V4L2 backend |

Measured: the same 1080p VP9 file costs 0.15 s of user CPU in hardware against
3.20 s in software.

Testing notes:

- mpv only hardware-decodes with an explicit flag. `--hwdec=auto`, `auto-safe`,
  `auto-copy` and the default all stay in software, because mpv's backend list
  offers the v4l2m2m wrappers only in the `-copy` variant.
- Identify a GStreamer decoder by plugin and object type, not element name:
  `v4l2h264dec` from the `video4linux2` plugin is the stateful M2M decoder
  this hardware needs; the similarly named elements from the `v4l2codecs`
  plugin are stateless and cannot drive this device.
- Fedora's `ffmpeg-free` lacks the H.264 and H.265 v4l2m2m wrappers (patent
  policy), so verifying H.264/HEVC hardware decode needs a full FFmpeg build.
- Prove hardware use with CPU time, not wall time — a hardware path can be
  slower in wall terms through copy overhead. The reliable fingerprints are
  the device holder and a low CPU figure.
- The VPU clocks are `gcc_video_axi0_clk` and `video_cc_pll0` (720 MHz idle →
  1.014 GHz active). The AXI clock's enable window is short, so a snapshot may
  miss it — sample repeatedly.

---

## Fingerprint and the secure world

| Item | Value |
|---|---|
| Sensor | EgisTec EL721, under-display optical |
| Driver | `kernel/files/egis_el721.c` → `/dev/esfp0` |
| Secure element | K250A (`snvm`) → `/dev/k250a` |
| Trustlet | signed `dualfp`, loaded through `qcomtee` |
| Coprocessor | SPSS/SPU stack (six ported modules) |

Status: the Linux half and the whole secure processor are up — the sensor's
3.3 V rail is published, the trustlet loads and verifies, and the SPU boots
with its Android userspace peers (`sec_nvm`, `spdaemon`). The session stops at
the TEE's `KEYMASTER_NOT_CONFIGURED`; what remains is the secure owner that
configures `sp_keymaster` and restores HwVault credential 11, plus panel
`cell_id`/HBM handling and a libfprint backend.

GNOME's unlock plumbing is already complete — Settings enrolment, GDM via PAM,
gnome-shell lock screen — and only needs libfprint to see a reader. On any
fingerprint port, check that split early: the desktop side is often finished
while the backend is missing entirely.

Notes for working in the secure world:

- Probe the trustlet read-only first, with a known-resident control; a passing
  read-only probe proves the TEE path before anything is risked.
- The TA lookup needs three parameters, not two — the reference documentation
  was wrong, and two parameters silently failed.
- Large payloads need OBJREF and a big-enough pool; a too-small shared pool
  fails in a way that does not point at the pool size.
- A coprocessor that connects once must boot after its peers. The SPU only
  boots once its NVM daemon and userspace peers are up; ordering, not driver
  code, was the blocker.
- Do privileged transitions in the object that owns the lifetime.
- Distinguish factory data from a derived cache: some "missing" partitions can
  be regenerated; others are per-unit calibration that must be preserved.
- The modules load at boot through `modules-load.d`; they need no
  device-tree node. (Earlier builds loaded nothing and needed a manual
  `modprobe` of each.)

---

## USB, Type-C and docks

| Item | Value |
|---|---|
| Debug net | USB ECM gadget at `172.16.42.1` |
| USB-PD | SM5714 USB-PD / TCPM (`sm5714_usbpd.c`) |
| Redriver | `ps5169.c` |
| DisplayPort | alt-mode, with a deferred-HPD workaround |

The debug gadget was originally RNDIS and was flaky under sustained sessions
and suspend cycles; converting it to ECM fixed the host binding. Host mode, PD
and docks work.

---

## Cross-cutting notes

- Everything built `=y` needs a rebuild and a `boot.img` flash; anything that
  can be a module can be iterated without reflashing.
- A kernel enum change and its module consumer must ship together, or you get
  silent misbehaviour rather than a build error.
- DSP firmware can be loaded live with a preload switch where the hardware
  allows it, instead of rebooting.
- Read driver state through its own ABI before patching it.
- The vendor kernel source is the reference for register maps, rail
  assignments and stock sequencing — use it as documentation even when running
  mainline.
