# Porting Guide

The transferable part of this project: the method — the order of work, the
layers that have to line up, and the mistakes that cost the most time when
bringing Linux up on an Android tablet. The device-specific traps live in
[Hardware Notes](Hardware-Notes.md).

It is written from one Qualcomm/Samsung port, so treat the specifics as examples
and the structure as the reusable part.

---

## The layering rule

**Locate the missing layer before estimating any work.** When something does not
work on a SoC, the cause is in exactly one of these, and they are wildly
different projects:

| Layer | Typical size | Can you write it? |
|---|---|---|
| Kernel driver | weeks–months | often already exists in mainline — **check first** |
| Firmware | effectively never | vendor-signed, PAS-authenticated blobs; patching is the state of the art, replacement is not realistic |
| Userspace API bridge | days–weeks | usually the real answer |
| Application integration | days | a build flag or a preference |

"Write a driver" is almost never the answer for a mainline-supported SoC. Check
`drivers/…/<vendor>/` before assuming anything — it is frequently present, GPL,
and actively patched upstream. On this device the video decoder driver was
already in mainline, already running, and already decoding; the genuinely missing
piece was a userspace bridge.

Corollary: when the **hardware API shape mismatches the app's API shape** (say,
a surface-based API against a linear capture queue), that mismatch *is* the
project. Budget for it explicitly instead of discovering it halfway in.

---

## Step 1 — Establish the boot chain

You cannot boot anything until you can put bytes on the device and have the
bootloader run them. Do this first, and do it from the stock firmware's own
format rather than inventing a scheme.

### Learn the stock layout before changing it

Read the stock partitions and map them. On this device the stock boot chain is
Android boot-image **v4**:

| Partition | Size | Role |
|---|---|---|
| `boot` | 96 M | `ANDROID!` header v4, kernel `Image` + **appended mainline DTB** |
| `init_boot` | 8 M | generic ramdisk; too small for a real initramfs, so the bundle ships an empty cpio and the full initramfs rides in `vendor_boot` |
| `vendor_boot` | 96 M | `VNDRBOOT` header, vendor ramdisk + **cmdline + bootconfig**; **its DTB is the one the bootloader actually loads** |
| `dtbo` | 16 M | deliberately invalid (all zeros) → forces the bootloader's *DeviceTreeAppended* fallback |
| `vbmeta` | 128 K | zeroed (verified boot disabled, flags 2) |

Two traps worth internalising:

- **The cmdline lives in `vendor_boot`, not in the kernel.** Anything that
  normally edits kernel arguments (`bootc` kargs, a bootloader config, GRUB) has
  no effect here. Kernel updates mean rebuilding and reflashing the bundle.
- **The DTB that matters may not be the one you think.** Verify against the live
  FDT, not against the file you wrote.

### Get the sizes right, from the device

Re-verify partition sizes on the device (`blockdev --getsize64` under TWRP)
rather than trusting an earlier capture. Two sizes in this project's first
capture were simply wrong, and a wrong size in a flash script is how you brick a
partition.

### Make flashing safe

The installer should refuse to run unless it can confirm:

- the device is in recovery, with the expected **codename and model**;
- every target partition is the expected size;
- it is writing **only** the boot-chain partitions — never `userdata`, never
  `super`, never EFS, never recovery;
- the user has explicitly acknowledged data loss, with a typed confirmation.

It should also not reboot on its own, so a failed flash can be inspected.

### Keep a rollback

Keep the previous bundle and reflash it. A rescue root on removable media that
boots **by the same root UUID** is worth having — but then make sure exactly one
of the two is ever present, and say so loudly in the documentation.

---

## Step 2 — Kernel

### Start from mainline, not from the vendor tree

Bring the device up on mainline with a small patch set plus out-of-tree drivers,
rather than carrying a vendor kernel. On this port that is mainline 7.2-rc3 with
about 20 patches and a handful of out-of-tree drivers (touchscreen, panel,
charger, USB-PD, fuel gauge, redriver, pen digitizer), plus a board DTS and a
config fragment.

The vendor kernel source is still invaluable — as **reference**, not as a base.
It answers "what does this register mean", "which rail does this sensor use",
"how does stock sequence this device". Read the vendor's symbol table when a
driver needs a bus or a rail you cannot otherwise identify.

### Device tree work

- **Test bindings by running the driver, not by grepping.** A binding can look
  perfectly correct and never bind. Only a probe tells you.
- **Check for self-publishing DT nodes before writing DTS.** Some drivers create
  their own nodes; adding a node for them is wasted work and can conflict.
- **An in-DT address sweep finds silent I2C sensors.** When a sensor on a known
  bus does not respond, sweeping plausible addresses in the device tree is often
  faster than any other method — this is how the front camera's wrong address was
  found (the DTS carried the EEPROM's address instead of the sensor's).
- **Recover board bindings from a DTBO's `__fixups__` table.** The fixups tell
  you which symbols the stock overlay expected, which is a direct answer to
  "what did the vendor's board file bind?".

### Config and modules

- **A silent `sed` no-op makes a Kconfig symbol vanish.** Verify insertions
  landed; do not assume the config edit took.
- **A kernel enum change and its module consumer must ship together.** If you
  change an enum and rebuild only one side, you get silent misbehaviour, not a
  build error.
- **Adding a kernel feature without reflashing** is possible via loadable
  modules, which is enormously faster for iteration than a boot-image round trip.
- **Load DSP firmware live** with a preload switch rather than rebooting.

---

## Step 3 — Firmware and blobs

This is usually where the schedule goes.

### You cannot replace vendor firmware

Codec and DSP firmware is typically a proprietary, vendor-signed, authenticated
blob. The realistic state of the art for such firmware is **patching**, not
replacement. Plan around obtaining the vendor's blob, not around writing your
own.

### Locating blobs

- **Sweep sibling ports first.** Other ports of the same or a closely related
  device are the single best source of blobs and driver code, and they have
  usually already solved the packaging questions.
- **On a dual-boot tablet, the blobs are already on the device.** Extracting
  them from the stock partitions is reliable and keeps you legal.
- **Distinguish factory data from a derived cache** before concluding something
  is irrecoverably lost. Some partitions can be regenerated; others are
  per-unit factory calibration and must be preserved.
- **A firmware payload can carry files nothing loads.** Do not assume that
  because a blob is present it is in use — check `dmesg` and the consumer.

### The trap that cost the most time here

`linux-firmware` shipped a whole family of blobs for this VPU (`vpu30_*_s*`) but
**not the one this device needs** (`vpu30_4v.mbn`). The device tree and driver
were both correct and `/dev/video17` registered — the firmware load simply failed
with `ENOENT`, and the driver logged nothing at probe time. The fix was one file,
staged with a pinned checksum.

Two lessons:

- **Verify the exact blob name the device asks for**, not that "a blob for this
  chip family exists".
- **Stage firmware with a pinned checksum and fail loudly.** A silent fallback
  here means a device that boots and quietly decodes in software — the worst kind
  of bug, because everything looks fine.

---

## Step 4 — Rootfs and staging

### Ownership is load-bearing, and its failure is silent

`systemd-tmpfiles` refuses to canonicalize any path under a non-root-owned
directory. If the top of your staged rootfs is owned by the build user, **every**
`tmpfiles.d` entry in the image is inert — and on Fedora the unit still reports
success, because it carries `SuccessExitStatus=DATAERR CANTCREAT`, so
`systemd-tmpfiles-setup.service` exits 73 on every boot while reading
`active (exited)`.

Two mechanisms cause this, both confirmed by experiment:

- `cp -a src/. dst/` applies the **source** owner to the destination directory
  *itself* — so copying an overlay chowns `/` and `/etc` to the checkout's uid;
- a `usr/` directory entry inside a tarball chowns `/usr` to the uid recorded on
  that entry.

Fix it at the end of staging: use the package manager's own restore
(`rpm -a --setugids --setperms`) for packaged files, then chown the non-package
trees — **each entry and every parent directory leading to it**, because the
ancestors are what systemd canonicalizes. Do **not** blanket-chown: that strips
legitimate service-account ownership such as `root:systemd-journal`,
`apache:apache` and `abrt:abrt`.

### Capabilities travel separately from ownership

Packing with plain `tar` and no `--xattrs` silently drops
`security.capability`. `rpm -Va`'s capability column is the cheap detector. The
failure is invisible because unprivileged `ping` still works via
`net.ipv4.ping_group_range` — what breaks is rootless containers and
`unshare -r`, which need `newuidmap`/`newgidmap` to carry their capabilities.
Fixing it requires `--xattrs` on **both** packing and every extraction path,
including whatever runs on the flashing path.

### General rule

Ownership and capabilities travel together, and both are dropped by ordinary
copy and archive operations unless you explicitly preserve them. Verify on the
booted device, not in the build tree.

---

## Step 5 — Userspace services

### Coprocessor bring-up is an ordering problem

A coprocessor that connects once must boot **after** its peers. If your DSP or
secure-processor daemon starts before the services it talks to, it fails and does
not retry. Ordering, not driver code, is usually the fix.

### systemd traps that cost real time

- **Sleep hooks are read only from `/usr/lib/systemd/system-sleep/`** on systemd
  259. A copy under `/etc/…` is silently inert, which is a nasty failure: the
  hooks look installed and never run.
- **`PathExists=` plus a oneshot that exits immediately loops forever.** A path
  unit re-triggers itself — this project measured 16,137 restarts in a single
  boot at ~44 Hz, which alone made the session unusable. Add
  `RemainAfterExit=yes`.
- **After resume, wait on the pending job, not on `ActiveState`.** A queued but
  not-yet-executed job leaves the target reading `inactive`, so waiting on state
  returns immediately and you restart services too early.
- **Broken resume mimics feature defects.** A feature that "does not work after
  waking" is frequently a resume path that restarts nothing. Check resume before
  blaming the feature — this produced two false bug reports on this port.

### Audio

Audio on these devices is usually a UCM (ALSA use-case manager) job plus
firmware for the amplifier DSPs. Note that `linux-firmware` may ship **no**
blobs for your amplifier at all, and that a speaker-protection DSP is what makes
it safe to raise volume — do not raise per-amp volume before the protection
firmware actually loads.

---

## Step 6 — Verification discipline

Most of the expensive mistakes in this project were measurement mistakes, not
code mistakes.

- **Prove by running, not by grepping.** Presence of a code path, a string in a
  binary, or a capability in a driver is not proof it is used.
- **Measure CPU time, not wall time.** A hardware path can be *slower* in wall
  terms because of copy overhead while using a fraction of the CPU. CPU-seconds
  is the discriminator.
- **Read the column header before trusting a column index.** A wrong column index
  produced meaningless "clock is off" readings for a while; the real evidence came
  from independent checks (device holders, CPU) and those conclusions survived.
- **A test harness that mimics the product defect is the most expensive kind.**
  A local HTTP server that answered range requests with `200` made a browser
  abort media playback, which looked exactly like a decoder stall. Before
  concluding a feature is broken, make sure your harness is not the bug.
- **Absence of a log line is weak evidence.** Some code paths never log on
  success, and some logging configurations silently produce nothing.
- **Verify headless and GUI separately.** A headless browser may never attempt
  hardware paths at all, so a headless run cannot answer whether a desktop
  session can use them.
- **Sensor rotation is invisible metadata.** Verify orientation by eye; a
  rotation matrix is not observable from the sensor values.

---

## Reusable lessons, grouped

Short takeaways from this port, worth reading before starting a similar problem.

### Method

- **Check which layer is missing before writing a driver** — driver, firmware,
  API bridge and app integration are different projects.
- **Test DT bindings by running the driver**, never by grepping.
- **Read driver state through its own ABI** before patching anything.
- **Vendored reference patches can be malformed** — verify the patch landed.
- **A silent `sed` no-op makes a Kconfig symbol vanish.**
- **Recover board bindings from a DTBO's `__fixups__` table.**
- **Sweep sibling ports for blobs and drivers** before writing anything.
- **Size an API adapter by measuring existing ones** — the surviving
  VA-API-over-V4L2 projects are ~5,000–6,000 lines of C for three codecs, which
  makes a comparable backend a bounded project rather than a research program.
- **Locate vendor-signed firmware on a dual-boot tablet** rather than
  synthesising it.
- **Distinguish factory data from a derived cache** before calling it lost.

### Kernel and drivers

- **Find a silent I2C sensor address with an in-DT sweep.**
- **Check for self-publishing DT nodes before writing DTS.**
- **A kernel enum change and its module consumer must ship together.**
- **Add a kernel feature via modules, with no reflash**, to iterate quickly.
- **Load DSP firmware live** with a preload switch.
- **The vendor kernel source answers driver questions** — use it as reference.
- **Manual focus is not autofocus** — check every layer for an AF loop before
  assuming one exists.
- **A battery percentage cap is usually undercharging**, not a gauge bug.
- **Put battery bypass in the standard `charge_types` API**, not a private knob.
- **Sensor rotation is invisible metadata** — verify by eye.

### Firmware

- **A firmware payload can carry files nothing loads** — check the consumer.
- **Verify the exact blob name the device requests**, not that the family exists.

### Rootfs and packaging

- **A non-root-owned `/` silently disables `tmpfiles`** — and the failure is
  invisible on Fedora.
- **`tar` without `--xattrs` drops file capabilities.**
- **Rebase onto a re-created upstream via patch-id** — an empty
  `git merge-base --all` after a forced fetch means upstream was re-created, and
  `git cherry` identifies patch-equivalent commits so a rebase skips them.

### Userspace and systemd

- **systemd 259 reads sleep hooks only from `/usr/lib`.**
- **`PathExists` + a oneshot path unit loops forever** without
  `RemainAfterExit=yes`.
- **Wait on the job, not `ActiveState`**, after resume.
- **Broken resume mimics feature defects.**
- **A coprocessor that connects once must boot after its peers.**
- **Do privileged transitions in the object that owns the lifetime.**

### TrustZone and the secure world

- **Judge TrustZone-backed peripherals on a port** rather than assuming they are
  out of reach.
- **Probe TEE-backed peripherals read-only, with a known-resident control.**
- **Locate a TEE-owned sensor by probing it with its own trustlet.**
- **Drive a TEE peripheral with the sibling port's client.**
- **Large TEE payloads need OBJREF and a big-enough pool.**
- **Settle an ambiguous trustlet opcode direction with two probes.**
- **Fingerprint unlock is plumbing versus backend** — the desktop side may
  already be complete while the backend is missing.

### Media

- **A player reaches a VPU only via the decode API it speaks** — the relevant
  question is which API a program uses, not which codecs it supports.
- **Identify a GStreamer decoder by plugin and object type, not element name** —
  an element called `v4l2h264dec` may be the stateful M2M decoder you need, and
  the similarly named stateless one cannot drive your hardware.

---

## Prior art

Both are worth looking at before starting a Qualcomm Samsung tablet:

- **Azkali's work** — a mainline tree plus a firmware payload. Worth taking: the
  firmware payload, which solved two open issues here.
- **agcarbajo's port** — kernel and userspace subsystems, with documented
  failures worth heeding.

The pattern that repeats: the sibling ports had already solved the *blob*
questions, and this port had solved the *boot chain* and *rootfs* questions.
Sweep them early — it is much cheaper than re-deriving anything.
