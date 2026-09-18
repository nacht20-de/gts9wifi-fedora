# libcamera-hi1337

Patch adding a libcamera `CameraSensorHelper` for the SK Hynix HI-1337 as
found on the Galaxy Tab S9 Wi-Fi (`gts9wifi`), where the port registers the
sensor as **`hi1337-gts9u`**.

## Why

libcamera's software ISP refuses to create a sensor helper for an unknown
model:

```
IPASoft: Failed to create camera sensor helper for hi1337-gts9u
```

The helper is what converts between real analogue gain and the sensor's gain
register, and it is what supplies the sensor's black level. Without it the
IPA's AGC is inert — the sensor simply keeps whatever analogue gain it was
left at, in practice the **maximum (240 = 16×)**, giving a violently noisy
image — and the black-level correction is skipped, which shows as a **heavy
green cast** in the processed output.

Adding the helper fixes both: AGC actively meters and adjusts again, and the
processed image is correctly coloured.

## Values used

| Item | Value | Rationale |
|---|---|---|
| Gain model | `AnalogueGainLinear{ 1, 16, 0, 16 }` | Register `0x0213` holds codes 0..240 encoding `gain = 1 + code / 16`, i.e. 1×..16× — the same scheme libcamera already uses for the Hynix HM-1246 |
| Black level | `4096` | Pedestal 64 at 10 bits, scaled to 16-bit as `blackLevel_` requires (same convention as the IMX219 entry) |

## Applying

Built against Fedora's libcamera 0.7.1 source (`dnf download --source
libcamera`), so the rebuild matches the distro ABI:

```sh
# after extracting the libcamera source
patch -p1 < add-hi1337-gts9u-camera-sensor-helper.patch

meson setup build --buildtype=release \
    -Dtest=false -Ddocumentation=disabled -Dpycamera=disabled -Dqcam=disabled \
    -Dgstreamer=disabled -Dlc-compliance=disabled -Dpipelines=simple -Dv4l2=enabled
ninja -C build -j3 src/ipa/simple/ipa_soft_simple.so
sudo cp build/src/ipa/simple/ipa_soft_simple.so /usr/lib64/libcamera/ipa/
```

Only the soft-ISP IPA module needs replacing. It is the one module Fedora
ships **without** a `.sign` file (it runs as an in-process thread worker
rather than an isolated process), so no re-signing is needed — unlike
`ipa_rkisp1`/`ipa_rpi_vc4`/`ipa_mali_c55`.

## Verified

On a Galaxy Tab S9 Wi-Fi, while streaming through libcamera, the sensor's
`analogue_gain` now moves (`64 → 89 → 135 → 204 → 240`) as AGC meters,
where previously it never changed. A processed frame captured through
`libcamerasrc` shows natural colour instead of the previous green cast.

## Known limitation

This unlocks **AGC and correct colour**, but *not* focus control: libcamera
0.7.1's simple pipeline handler has no lens support at all (no `CameraLens`,
no `LensPosition` control), so no sensor helper can expose it. Driving the
`dw9808` VCM still requires direct V4L2 control of the lens subdev — see
the camera wiki page.
