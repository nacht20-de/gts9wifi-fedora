# TODO

Outstanding work, grouped by area. Each item says what is actually missing and
where the previous investigation stopped, so nobody has to rediscover it.

If you want to pick something up, the [Porting Guide](Porting-Guide.md) explains
the build and verification workflow, and [Known Issues](Known-Issues.md) has the
full history of each numbered issue.

---

## Kernel and boot

- [ ] **Preserve file capabilities through packing and flashing.** The rootfs is
      packed with plain `tar` and no `--xattrs`, so `security.capability` is
      dropped; ten binaries are affected, including `newuidmap`/`newgidmap`,
      which breaks rootless containers and `unshare -r`. Needs `--xattrs` on
      both the packing **and** every extraction path — including TWRP's `tar` on
      the flashing path — so it must be verified on the device.

- [ ] **Give the kernel cmdline a delivery path for updates.** `bootc` kargs do
      not reach ABL: the kernel cmdline lives in `vendor_boot`. Kernel updates
      therefore need a boot-image rebuild and reflash. This is the main open
      design point for an atomic image variant (a non-atomic image avoids it),
      and the same problem that Bluetooth address provisioning already solves
      on-device.

- [ ] **Test the encoder node.** `/dev/video18` (`iris_venc`) has never been
      exercised. Encoder support is being upstreamed, so newer kernels should
      work without new driver code.

- [ ] **SELinux is permissive.** Not enforced. Making it enforcing needs a
      policy for the device services and the Android-partition mounts.

- [ ] **RTC has no valid time before NTP.** Early-boot systemd timestamps read
      1970, because there is no RTC battery path in the port.

## Device bring-up

- [ ] **Fingerprint: under-display EgisTec EL721** (issue 15). The Linux half
      and the secure processor are up, but the session stops at the TEE's
      `KEYMASTER_NOT_CONFIGURED`. Concretely what remains:
  - [ ] the secure owner that configures `sp_keymaster` and restores HwVault
        credential 11;
  - [ ] panel `cell_id` / HBM handling;
  - [ ] a libfprint backend — GNOME's unlock plumbing (Settings enrolment, GDM
        via PAM, gnome-shell lock screen) is **already present** and only needs
        libfprint to see a reader;

- [ ] **Charging bypass on 25 W+ chargers** (issue 13). Hardware and stock
      support are confirmed and the kernel already has a `Bypass` charge type;
      the missing piece is userspace. Neither UPower 1.91.4 nor GNOME 50.4
      exposes a bypass control, so this needs a small `gnome-control-center`
      patch. Put the control on the standard `charge_types` API rather than a
      device-private knob.

- [ ] **Mount the Android `/vendor` (`super`) partition.** Needs a
      `make-dynpart-mappings` equivalent for Fedora. Requirements:
      `dm-linear` mapping of `super`'s dynamic partitions, `vendor` (erofs)
      read-only at `/vendor`, `dsp` (ext4) at `/vendor/dsp`, and `persist`
      mounted **read-write** at `/mnt/vendor/persist` because Samsung's sensor
      registry writes and Wi-Fi calibration live there. The usual
      copy-firmware-once tooling does **not** cover this device.

- [ ] **Speaker characterisation is missing.** Mainline's `wm_adsp` loads exactly
      one `.bin` per DSP, so the separate calibration deploy group is never
      applied and the limiter runs on nominal rather than measured speaker
      parameters. That is why the volume deliberately stops 7.25 dB below full
      scale. Investigate whether the calibration can be applied at all.

- [ ] **ADSP boot service is disabled by default** because starting the ADSP
      late can hang or reset the SoC. Root-cause it and enable it.

## Userspace and packaging

- [ ] **Get the patched userspace into a Fedora repository.** Several
      components are built from source because Fedora does not carry them or
      carries them unpatched:
  - [ ] `hexagonrpcd` with the port's two patches (large inbufs, Samsung sensor
        registry writes);
  - [ ] `iio-sensor-proxy` built **with libssc** plus the slow-sensor-discovery
        patch — check whether Fedora's build has libssc before assuming it
        works;
  - [ ] `libssc` and `pd-mapper`, which are not in Fedora at all.
      A COPR is the obvious home.

- [ ] **Optional desktop polish.** Some Alpine-side patches would need porting:
      `mutter` (accelerometer reclaim on a new SensorProxy owner),
      `gnome-control-center`, and `xorg-server`.

- [ ] **Package the GNOME extension properly.** The double-tap-to-wake settings
      page currently ships as a plain extension directory. Note that GNOME Shell
      50 does not rescan extension directories at runtime, so the extension is
      only discovered at session start.

## Media

- [ ] **Let browsers and VLC reach the VPU.** The decoder works; the gap is the
      API. `iris` exposes a **stateful V4L2 M2M** node and there is **no VA-API
      driver** for it, while Firefox, Chromium/Vivaldi and VLC all decode
      through VA-API (or VDPAU / a private decoder). Two routes:
  - [ ] **Write a VA-API driver over the stateful M2M node.** No kernel work is
        needed — a VA-API driver is a `dlopen`ed shared object located by a
        versioned init symbol. `struct VADriverVTable` has ~60 function pointers
        of which roughly 20 need real implementations. Size it by measuring
        existing work: the two surviving VA-API-over-V4L2 projects are only
        ~5,000–6,000 lines of C for H.264 + H.265 + VP9, but both target the
        **stateless** API, so this is a new backend rather than an adaptation.
  - [ ] **Or build Chromium with `use_v4l2_codec=true`.** Chromium already has
        a stateful V4L2 decoder in-tree, shaped for exactly this kind of driver,
        so this needs no new driver code. Note the usual caveats: this is an
        unofficial build path, and hardware video decode on non-ChromeOS Linux
        is unsupported by Google.

      A VA-API driver would also give `mpv --hwdec=vaapi` and fix VLC, so it is
      the broader of the two — and it is the layer that is actually missing.
      Check which layer is missing before writing a driver.

- [ ] **Note for anyone porting a different device:** the encoder node is
      untested and the VPU firmware is a vendor-signed blob, so it is not
      replaceable — patching vendor firmware is the state of the art, and it is
      a large project.

## Documentation

- [ ] Keep `docs/` in sync with the register in
      [Known Issues](Known-Issues.md). Issue numbers are stable and referenced by
      build scripts, so never renumber and never reuse a retired number.
