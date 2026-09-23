# Device controls

This port's tablet settings live behind one small helper,
`/usr/libexec/gts9wifi-device-control` (most of them in the kernel, where the drivers
keep them). The GNOME extension's settings page is built from that helper's table, so the
GUI and a terminal drive exactly the same switches.

| Control | Group | What it does | Default |
|---|---|---|---|
| Double tap to wake | Touchscreen | Wake the tablet from suspend by double tapping the screen | On |
| Fast charging | Power | Charges the battery faster by drawing more power from your charger. A 5 A USB-C cable is recommended | Off |
| Sleep instead of suspend | Power | The power button turns the screen off and locks the tablet but leaves it running, so Wi-Fi and downloads carry on. Off suspends the tablet, which is stock but drops it off the network until you wake it | Off |

## From GNOME

Open the Extensions app, find **gnome-gts9wifi** and press its settings button, or run:

```
gnome-extensions prefs gnome-gts9wifi@tabs9linux
```

Both switches are on that page. If a switch snaps back, the write was rejected — the rootfs on the tablet
may predate the control.

## From a terminal

```
gts9wifi-device-control list                 # every control, its label and its current value
gts9wifi-device-control get fast-charge
gts9wifi-device-control set fast-charge 1    # on
gts9wifi-device-control set fast-charge 0    # off
gts9wifi-device-control set power-button 1   # power button sleeps instead of suspending
gts9wifi-device-control apply                # re-apply every saved value
```

Values are `0` or `1` only. `set` also saves the value under `/var/lib/gts9wifi/`, and
`gts9wifi-device-control.service` re-applies it at every boot, so what you set survives a
reboot. Writing the kernel file directly (below) does **not** survive a reboot.

The helper needs write access to the file it drives. Those files belong to group `video` and
are mode `0664`, so a user in `video` can set them without `sudo`; otherwise prefix the
command with `sudo`.

## The files behind the switches

| Control | Kernel file |
|---|---|
| Double tap to wake | `/sys/bus/i2c/devices/10-0049/double_tap_to_wake` |
| Fast charging | `/sys/bus/i2c/devices/6-0049/fast_charge` |

So without GNOME, and without the helper, the same switches are:

```
echo 1 | sudo tee /sys/bus/i2c/devices/10-0049/double_tap_to_wake   # double tap to wake on
echo 0 | sudo tee /sys/bus/i2c/devices/10-0049/double_tap_to_wake   # off
echo 1 | sudo tee /sys/bus/i2c/devices/6-0049/fast_charge           # fast charging on
echo 0 | sudo tee /sys/bus/i2c/devices/6-0049/fast_charge           # off
```

These are lost at the next boot unless the value is also saved under
`/var/lib/gts9wifi/` — which is what `gts9wifi-device-control set` does.

The power button has no kernel file of its own: it is what GNOME does with a key press, so
that switch changes GNOME's settings instead. See below.

## Power button: suspend or sleep

Out of the box the power button suspends the tablet, which is what GNOME does. This port has
no wake-on-Wi-Fi, so a suspended tablet is **off the network**: ssh, downloads and anything
else remote stop until somebody presses the button again. **Sleep instead of suspend** keeps
the system running instead:

| | Suspend (off, default) | Sleep (on) |
|---|---|---|
| Power button | suspends the tablet | locks the session and turns the screen off |
| Screen | off | off |
| Wi-Fi, ssh, downloads | dropped until woken | carry on |
| Sitting idle afterwards | suspends after the timeout in Settings (5 minutes on this port) | never suspends |

Sleeping is a lock rather than a suspend: the session is locked and the screen is turned off,
while the system keeps running. Locking is what blanks the screen — gnome-settings-daemon
blanks the displays as soon as the screen shield comes up — and at the lock screen, where the
shield is already up and nothing changes, the displays are blanked directly instead. Any
input brings the screen back, still locked, so unlocking is the usual password or fingerprint
prompt.

The power key does both jobs, and which action it runs follows the display: while the screen
is on it sleeps the tablet, including at the lock screen, and while the screen is off it wakes
it. That split lives in `/usr/libexec/gts9wifi-power-key-watch`, a user service this switch
turns on. It is needed because one action cannot do both: by the time an action runs the
display may already be back, and sleeping it again would leave the tablet impossible to wake
with the power button.

One limit of sleeping: on GNOME a *touch* does not wake the display — keyboard and pointer
input do — so double-tap-to-wake applies to a suspended tablet, not to a sleeping one. Use
the power button, or any key, to wake a sleeping tablet.

Because "keeps running" has to include staying awake on its own, this switch also sets the
idle suspend timeout to *never* while it is on. Your own timeout is saved and put back when
you switch off again.

One limit: the setting is a per-user GNOME setting, so it governs the power key inside a
session. At the login screen no user session owns that key, so logind's own action applies
there; the helper writes the saved choice to
`/etc/systemd/logind.conf.d/10-gts9wifi-power-key.conf` at boot, where `ignore` means sleep
and `suspend` means stock.

## Fast charging in detail

- **Off (default)** keeps the stock behaviour: the SM5714 switching charger on the tablet's
  fixed 9 V USB-PD contract, about 15 W from the adapter.
- **On** hands the job to the SM5440 2:1 charge pump on a PPS contract. It roughly doubles
  the current going into the battery — measured on this port, about 23 W drawn from the
  adapter and 3.0–3.2 A into the pack, where the stock path managed about 2.1 A at the same
  state of charge.
- It needs a charger that supports **PPS** (Samsung's own fast chargers do), and a **5 A
  USB-C cable** for anything above 3 A. The tablet cannot read a cable's rating, so it stays
  at the spec-safe 3 A limit.
- Fast charging only applies at lower charge. The pump will not start above roughly 80 %
  (4.35 V) and stops at 90 %, so near full you may see the switch on while the tablet charges
  at the ordinary rate — the pump's own limits, not a fault.
- The switch is safe to leave on: turning it off at any moment parks the pump and hands the
  pack straight back to the switching charger.

## If a control is missing

`gts9wifi-device-control list` shows what the rootfs supports. The helper, its
udev rules and the kernel attributes ship from this repository's `rootfs/overlay` and
`kernel/files`, so a rootfs older than the control simply will not list it.
