# Known Issues

The port's live issue register. Numbers are the original report ids and stay
stable — other pages and build scripts reference them — so they are never
reused, and a retired number is simply absent rather than reassigned
(that is why there is no 8 or 12).

| # | Issue | Status |
|---|---|---|
| 1 | Battery percentage capped at 96 % | fixed — the charger's float voltage was never programmed, so the pack charged 60 mV short |
| 2 | No palm rejection (S Pen) | fixed — pen proximity now suppresses touchscreen input |
| 3 | Bluetooth lag under 2.4 GHz Wi-Fi | fixed — Samsung NVM/rampatch substituted for the generic ones |
| 4 | Rear camera (13 MP HI1337 + DW9808 lens) | works — manual focus only; a fixed focus of 384 ships |
| 4b | Front camera (12 MP HI1337) | works |
| 5 | No rotation sensor | works — needed a patched `iio-sensor-proxy` |
| 6 | USB debug link flaky | fixed — RNDIS gadget converted to ECM |
| 7 | Weak 5 GHz Wi-Fi RX | fixed — board-data (BDF) substitution, ~47 dB improvement |
| 9 | Discord/Roblox unreachable (DPI) | fixed — kernel rebuilt with `nfqueue` |
| 10 | Front camera did not probe | fixed — wrong I2C address in the DTS |
| 11 | libcamera had no sensor helper, so max gain | fixed — helper added, AGC runs |
| 13 | Charging bypass on 25 W+ chargers | planned — needs a `gnome-control-center` patch |
| 14 | Double tap to turn on the screen | fixed — with a GNOME extension UI |
| 15 | Under-display fingerprint sensor (EgisTec EL721) | in progress — blocked at the TEE's `KEYMASTER_NOT_CONFIGURED` |
| 16 | Hardware video decode (iris / VPU 3.0) | fixed — the VPU decodes; application support is partial |
| 17 | Speaker volume capped (~−19 dB) | fixed — Cirrus speaker-protection DSP firmware now loads |
| 18 | `/`, `/etc`, `/usr` owned by the image build user | fixed — this had silently disabled *every* `tmpfiles.d` entry |
| 19 | Kernel log flooded by ADSP handover messages | fixed — the repeat is logged at debug level now |

Also outstanding, not in the numbered register:

- the S Pen tilt sensor;
- the Android `/vendor` (`super`) partition is not mounted — needs a
  `make-dynpart-mappings` equivalent (see below);
- SELinux runs permissive;
- file capabilities are lost when the rootfs is packed (see below);
- the VPU encoder node `/dev/video18` is untested;
- early-boot timestamps read 1970 — the RTC has no valid time before NTP;
- `gts9wifi-adsp-boot.service` ships disabled: starting the ADSP late can hang
  or reset the SoC, and it needs root-causing;
- the patched userspace is built from source at image build time rather than
  shipped from a Fedora repository — `hexagonrpcd` (two patches),
  `iio-sensor-proxy` with libssc, and `libssc`/`pd-mapper` (not in Fedora at
  all); a COPR is the obvious home;
- the GNOME extension ships as a plain directory — GNOME Shell does not rescan
  extension directories at runtime, so it needs proper packaging;
- browsers and VLC still decode in software: the VPU has no VA-API driver. Two
  routes: a VA-API driver over the stateful M2M node (the surviving
  VA-API-over-V4L2 projects are ~5,000–6,000 lines of C for three codecs, but
  both target the stateless API), or a Chromium build with
  `use_v4l2_codec=true` (an unofficial build path, unsupported by Google).

---

## Open issues in detail

### 13 — Charging bypass on 25 W+ chargers

Running the tablet from the adapter instead of the battery pack, with a toggle
in *GNOME Settings → Power*.

The hardware and stock support are confirmed: `battery,ovp_bypass_mode` plus two
register writes, and the kernel already has a `Bypass` charge type. What is
missing is purely userspace — **neither UPower 1.91.4 nor GNOME 50.4 exposes a
bypass control**, so this needs a small patch to `specs/gnome-control-center`.
The correct place for such a control is the standard `charge_types` sysfs API
rather than a device-private knob.

### 15 — Under-display fingerprint sensor (EgisTec EL721)

The Linux half and the whole secure processor are up on the tablet:

- the ported EL721 driver, exposing `/dev/esfp0` with the 3.3 V rail published
  and `gpio155` driven;
- the K250A secure element (`snvm`) live as `/dev/k250a`;
- the signed `dualfp` trustlet loading through `qcomtee`;
- the SPSS/SPU stack (six ported modules) booting the SPU with its Android
  userspace peers — `SP Apps were loaded successfully`, `SP Build v73.6`,
  remoteproc `running`.

The session still stops at the TEE's `KEYMASTER_NOT_CONFIGURED` (cache status
`9936`). What remains is the secure owner that configures `sp_keymaster` and
restores HwVault credential 11, then the panel `cell_id` / HBM handling and a
libfprint backend.

**GNOME's unlock path is already present** — Settings enrolment, GDM via PAM
and the lock screen via gnome-shell — and only needs libfprint to see a reader.

Notes:

- The modules load at boot through `modules-load.d/gts9wifi-fingerprint.conf`,
  so `/dev/esfp0` and `/dev/k250a` exist on a plain boot. They need no
  device-tree node — the live FDT has none. (Earlier builds loaded nothing and
  needed a manual `modprobe` of each.)
- Judge the trustlet read-only before porting anything, with a known-resident
  control, and beware that the TA lookup needs **three** parameters, not the two
  the reference documentation suggests.

### `/vendor` — the Android `super` partition is not mounted

The working system needs the Android partitions at runtime, not just at
first-boot extraction:

- `make-dynpart-mappings /dev/disk/by-partlabel/super` creates a `dm-linear`
  mapping of the dynamic partitions, giving `/dev/mapper/vendor`;
- `super/vendor` is **erofs** and mounts read-only at `/vendor`;
- the `dsp` partition (ext4) mounts at `/vendor/dsp`;
- the `persist` partition mounts **read-write** at `/mnt/vendor/persist`,
  because Samsung's sensor registry writes and Wi-Fi calibration live there.

`make-dynpart-mappings` has **no Fedora equivalent yet**. Worst case: port it,
or replicate the device-kit approach. Note that the usual
"copy-firmware-once" tooling does not cover this device, precisely because
`persist` needs a permanent read-write mount and `super`/`vendor` need live
mapping.

### SELinux runs permissive

Not enforced.

### File capabilities are lost when packing the rootfs

The rootfs is packed with plain `tar -C "$rootfs" -czf "$archive" .` — with no
`--xattrs`, so `security.capability` xattrs are dropped. `rpm -Va` lists exactly
ten capability mismatches (`/usr/bin/newuidmap`, `/usr/bin/newgidmap`, several
`sssd` helpers, `/usr/bin/arping`, `/usr/bin/clockdiff`, `/usr/bin/suexec`,
`/usr/bin/mtr-packet`, `snap-confine`), and the live system's `newuidmap` and
`arping` have no `security.capability` xattr at all.

The failure is **invisible** because unprivileged `ping` still works — the
`net.ipv4.ping_group_range` sysctl masks it. What actually breaks is rootless
containers and `unshare -r`, which need `newuidmap`/`newgidmap` to carry their
capabilities.

Fixing it needs `--xattrs` on **both** the packing and every extraction path,
including TWRP's `tar` on the flashing path, so it has to be verified on the
device rather than only in the build.

---

## Fixed issues — what they were

### 1 — Battery percentage capped at 96 %

Not a fuel-gauge bug. The SM5714 charger's **float voltage was never
programmed**, so the pack was charged 60 mV short of full. Once programmed, the
tablet reaches 100 %.

### 2 — No palm rejection (S Pen)

The S Pen digitizer and the touchscreen are fully independent input devices.
The touchscreen controller already classifies palm contacts, but the driver
reported every accepted touch type (normal/glove/palm/wet) as a plain finger,
and nothing coordinated the pen's hover state with the touchscreen.

The fix tracks pen proximity and exposes a "should suppress touch" query with a
**250 ms silence timer**, so proximity clears even if the digitizer stops
sending frames when the pen is lifted. The touchscreen calls it at the top of
its handler; while the pen is in range it releases all finger slots and drops
incoming touches. This has to be kernel-level: userspace arbitration can only
reason about touches near the pen's last position, and gets permanently confused
if the pen is not seen at all.

### 3 — Bluetooth lag under 2.4 GHz Wi-Fi

Fixed by substituting Samsung's device-tuned WCN6855 NVM/rampatch for the
generic `linux-firmware` ones, which keeps the BT keyboard and audio lag-free
while 2.4 GHz Wi-Fi is active.

### 5 — Rotation sensor

The SSC sensors are alive and ambient light is served to the desktop, but
`iio-sensor-proxy`'s orientation property never turned true. This was an
upstream proxy/libssc issue, not a configuration problem, and is fixed by a
patched `iio-sensor-proxy` built with libssc.

Note that **sensor rotation is invisible metadata** — a rotation matrix is not
observable from the sensor values, so it has to be verified by eye.

### 6 — USB debug link flaky

The RNDIS gadget was converted to ECM.

### 7 — Weak 5 GHz Wi-Fi RX

The ath11k board-data (BDF) file was substituted. Three plausible causes were
ruled out first; the Samsung BDF itself made ath11k worse.

### 9 — Discord/Roblox unreachable (DPI)

The kernel had been built without `nfqueue`, so the DPI-bypass tool had nothing
to work with. Rebuilt with `nfqueue`; both services returned to `200`.

### 10 / 11 — Camera

The front sensor did not probe because the DTS carried the **EEPROM's** I2C
address (`0x20`) instead of the sensor's (`0x21`) — an in-DT address sweep found
it. Once probing, it streams 3408×2556 @ 30 fps. Separately, libcamera had no
sensor helper for this part, so automatic gain control never ran; adding the
helper fixed it.

### 14 — Double tap to turn on the screen

The driver arms the stock gesture (sponge mode, plus two register writes), keeps
the rails on and enables the IRQ as a wake source, reports `KEY_WAKEUP`, and
registers as a wake source. Verified: a suspend entry was ended by a tap after
12.7 s of sleep, while the 150 s RTC fallback never fired.

There is a UI: a GNOME Shell extension settings page toggles it through a
device-control helper, the choice is saved under `/var/lib/gts9wifi/` and
re-applied at boot, and a udev rule makes the touchscreen attribute
group-writable so no privilege prompt is needed. There is deliberately no Quick
Settings toggle.

An earlier "the screen stays dark after a gesture wake" report was **not** a
double-tap defect — it was a broken resume path that restarted nothing.

### 16 — Hardware video decode (iris / VPU 3.0)

The driver and device tree were already in place and `/dev/video17` registered,
but the firmware load failed with `ENOENT` for `qcom/vpu/vpu30_4v.mbn`.
`linux-firmware` ships a whole `vpu30_*_s*` family but **not this one**, and the
CI firmware payload does not carry it either.

The Samsung-signed blob is staged at build time with a pinned SHA-256 (fatal
on mismatch) — `rootfs/stage-public-firmware.sh` in CI,
`fetch-local-assets.sh` locally — so the decoder boots. **No kernel rebuild
and no reboot are needed** — the firmware loads on the first `open()` of
`/dev/video17`.

Verified: 90 frames of VP9, 150 of H.264 and 150 of HEVC all decoded through
`iris_driver` in mplane mode with zero errors; the video clock went from
disabled to 1.014 GHz; the same 1080p VP9 file costs 0.15 s of user CPU in
hardware against 3.20 s in software.

The remaining limitation is application support, not the decoder — see
[Home](Hardware-Notes.md#hardware-video-decode).

### 17 — Speaker volume capped

`linux-firmware` ships **no** CS35L45 blobs at all, so the Cirrus
speaker-protection DSP firmware had never been loaded and the DSP limiter was
not bounding cone excursion. The firmware now ships and loads on all four
amplifiers, so the per-amp volume was raised about 12 dB (380 → 428, that is
−19.25 dB → −7.25 dB, where 457 is 0 dB) and confirmed good by ear.

Two caveats: 7.25 dB is deliberately held back, and the speaker
*characterisation* is still missing — the two coefficient files are not
duplicates, and mainline's `wm_adsp` loads exactly one `.bin` per DSP, so the
separate calibration deploy group is never applied. That is also why the volume
is not simply pushed to 0 dB.

### 18 — `/`, `/etc` and `/usr` owned by the image build user

`systemd-tmpfiles` refuses to canonicalize any path under a non-root-owned
directory, so **every** `tmpfiles.d` entry on this port was inert — and
`systemd-tmpfiles-setup.service` exited 73 on every boot while still reporting
success, because Fedora's unit carries
`SuccessExitStatus=DATAERR CANTCREAT`.

Measured: 125 *unsafe path transition* errors per run, 2,757 wrongly-owned
entries outside `/home`, and 2,429 packaged files flagged by `rpm -Va`
(including `/`, `/etc` and `/usr`).

Two mechanisms, both confirmed by experiment:

- `cp -a src/. dst/` applies the **source** owner to the destination directory
  *itself*, so the overlay copy chowned `/` and `/etc` to the checkout's uid;
- a `usr/` directory entry in the firmware tarball chowns `/usr`, so it took the
  dev host's uid.

The fix restores ownership at the end of staging: rpm's own
`--setugids --setperms` for packaged files, plus a targeted chown of the overlay
and firmware trees — each entry **and every parent directory leading to it**,
because the ancestors are what systemd canonicalizes. It is deliberately **not**
a blanket `chown -R root:root`, which would strip `root:systemd-journal`,
`apache:apache`, `abrt:abrt` and similar legitimate service-account ownership.

Verified on the tablet: tmpfiles exit 73 → 0, unsafe-path errors 125 → 0,
`rpm -Va` owner/group mismatches 2,429 → 2.

Note that `rpm -a --setugids --setperms` exits 255 with a handful of
*restored failed* errors, because some packages list `__pycache__/*.pyc` files
that do not exist in the built image. This is benign — rpm still restores
everything it can — so the build treats a non-zero exit as a note rather than an
error.

### 19 — Kernel log flooded by ADSP handover messages

`Handover signaled, but it already happened` repeated at roughly **5.4 times
per second** — 99.98 % of the `dmesg` ring (37,402 of 37,411 lines), evicting
real diagnostics within seconds. The handover interrupt is level-triggered and
the remote keeps it asserted after the first handover, so the repeat is
expected and harmless. Fixed by logging it at debug level
(`quiet-adsp-handover-already-happened.patch`); no behaviour change.
