# Wi-Fi on gts9wifi (QCA6490 / WCN6855) — investigation notes

> **Internal development notes.** Everything learned while chasing the
> 5 GHz no-IR problem on the Tab S9 Wi-Fi. Companion to
> [PORT-KIT.md](PORT-KIT.md); not end-user documentation.

Captured September 2026, tablet running kernel
`7.2.0-rc3-gts9wifi` ("v8", flashed locally from
`/home/dq/kbuild-gts9/linux-7.2-rc3/`).

## Hardware & firmware recap

| Item | Value |
|---|---|
| Wi-Fi/BT SoC | Qualcomm WCN6855 (dual chip, reports `QCA6490`) |
| ath11k | `ath11k_pci`, hw_params reports **hw2.1** |
| Firmware `amss.bin` | md5 `9f8dd9ecbc75e5041570dacf48f98874` — **identical** between Samsung's build (Jul 18) and linux-firmware (Aug 11) — stock Qualcomm, NOT Samsung-custom |
| Board data (BDF) | `/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin` |
| Regulatory data | `regdb.bin` (24310 bytes) + embedded regdb IE in board-2.bin (`bus=pci` fallback) |
| Regulatory mode | wiphy is **self-managed** (`phy#0 (self-managed)` in `iw reg get`) — the **firmware** decides channel flags, not cfg80211 |

### Board-data sources tried

| Source | board-2.bin md5 | Notes |
|---|---|---|
| Samsung (stock, backed up) | (original in `/lib/firmware/ath11k/samsung-backup-hw21/`) | has the per-device RF calibration entry for subsystem `17cb:0108`; ~7.2 MB |
| linux-firmware (currently installed) | `df8157b9a251ac6c662b91df94a45438` | generic WCN6855 BDF; 58180-byte `board.bin` for fallback |

All regdb blobs inspected (file `regdb.bin`, Samsung's board-2.bin REGDB IE,
linux-firmware's) are the **standard Qualcomm regulatory database** (first
country "AF"), 239 country tokens vs the regdb.bin file's 203. Nothing
Samsung-conservative hiding in the BDF.

## Root cause chain of the 5 GHz failure

1. The WCN6855 firmware marks **all 5 GHz channels `REGULATORY_CHAN_NO_IR`**
   (passive-only). Because the wiphy is self-managed, this flag reaches
   cfg80211 verbatim via `ath11k_map_fw_reg_flags` (reg.c) and 5 GHz was
   effectively dead: passive scan only, no connection.
2. Country hints (`iw reg set TR/US/…`) were accepted (phy#0 output changed)
   but the firmware never cleared 5 GHz no-IR — it is the firmware's own
   enforcement, on top of the QCA regdb the driver loads.

### Three things that *looked* like the cause but were not

- **"wifi crashed connecting to 5 GHz"** — never reproduced; no firmware
  assert, no `fw_crash`/recovery messages, dmesg clean. The failure was a
  clean `-EINVAL` from cfg80211.
- **`iw connect … 36` → `EINVAL (-22)`** — `iw` parses the trailing number as
  a **frequency in MHz**, so ch36 = 36 MHz = invalid frequency. The correct
  channel syntax is `-36`; the correct sparse syntax is the **frequency
  (5180)**. Many EINVAL reports were this parser artifact, not a channel ban.
- **Samsung's board data** — its embedded regdb is standard QCA data, so it
  was not the source of the no-IR flags.

## Fix that made 5 GHz active (kernel v8)

- Enabled in the kernel config (see `kernel/files/config-gts9wifi.fragment`):
  - `CONFIG_EXPERT=y`
  - `CONFIG_CFG80211_CERTIFICATION_ONUS=y`
  - `CONFIG_ATH_REG_DYNAMIC_USER_REG_HINTS=y` (Kconfig dep chain:
    EXPERT → CERTIFICATION_ONUS → ATH_REG_DYNAMIC)
  - `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n` (patched in `net/wireless/Kconfig`)
  - `CONFIG_EXTRA_FIRMWARE="regulatory.db"` embedded in the kernel
  - `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=n`
- **NO_IR strip patch** in `drivers/net/wireless/ath/ath11k/reg.c`
  (`ath11k_map_fw_reg_flags`): only apply `NL80211_RRF_NO_IR` when the rule
  also carries `REGULATORY_CHAN_RADAR`. Non-DFS 5 GHz (UNII-1/UNII-3) lose
  no-IR; DFS channels keep it. After the patch `iw phy` shows ch36 etc. as
  **active** with 20 dBm TX.

The `CONFIG_ATH_REG_DYNAMIC_USER_REG_HINTS` path matters less than expected
since the wiphy is self-managed — the decisive change is the NO_IR strip +
active-capable channels.

## Verified end-to-end (WPA2-PSK, ch36)

Proved with wpa_supplicant (networkmanager stopped first, `scan_freq=5180`
to lock scanning to 5 GHz):

- SSID `SUPERONLINE_WiFi_5G_1030`, `freq=5180`, BSSID `8c:15:c7:ef:d7:fa`
- `wpa_state=COMPLETED` — 4-way handshake succeeded on ch36
- `rx bitrate 6.0 MBit/s`, `tx bitrate 234.0 MBit/s VHT-MCS 3 80MHz VHT-NSS 2`
  → full 802.11ac VHT-80 TX works
- No firmware crash, no ath11k errors in dmesg

Test recipe (SSID of the test home router, not generic):

    systemctl stop NetworkManager
    cat > /tmp/wpa5.conf <<EOF
    ctrl_interface=/run/wpa_supplicant
    network={
      ssid="SUPERONLINE_WiFi_5G_1030"
      psk="<psk>"
      scan_freq=5180
    }
    EOF
    wpa_supplicant -B -i wlp1s0 -c /tmp/wpa5.conf -D nl80211
    sleep 10
    wpa_cli -i wlp1s0 status    # wpa_state should be COMPLETED
    iw dev wlp1s0 link

Note: `dhclient` is NOT installed in the rootfs; NetworkManager
handles addressing. Restore it after testing: `systemctl start NetworkManager`.

## ⚠️ Current state at time of writing: connects, but no signal/data

After all fixes, the tablet **associates** on ch36 (`wpa_state=COMPLETED`)
but is effectively unusable — the link sits at **-87…-90 dBm** while the
same router's 2.4 GHz radio shows **-27 dBm**. ~60 dB asymmetry across two
radios of the same AP strongly suggests the 5 GHz RF path is not properly
calibrated/tuned, not a range issue.

Primary suspect: the installed **linux-firmware generic board-2.bin**
(lacks the per-device `17cb:0108` RF calibration that Samsung's BDF carries),
or the 5 GHz power-amplifier/LNA settings inside it.

### Next steps (not yet done)

1. **Restore Samsung's original board-2.bin** from
   `/lib/firmware/ath11k/samsung-backup-hw21/` and re-run the WPA2 ch36 test
   above. The kernel NO_IR strip should keep channels active even if the
   firmware still emits no-IR for 5 GHz.
2. If still weak, compare `iw phy phy0` channel TX power / supported
   bandwidths between the two BDFs; check the RF parameter fields
   (tx power limits, per-channel power) in both board-2.bin images.
3. Correlate with a known-good 5 GHz RSSI: walk the tablet near the AP and
   watch `wpa_cli signal_poll`.

## Kernel source landmarks

- `drivers/net/wireless/ath/ath11k/reg.c` — `ath11k_map_fw_reg_flags`
  (~line 321, NO_IR patch), `ath11k_reg_build_regd`, `ath11k_reg_set_cc`
- `drivers/net/wireless/ath/ath11k/wmi.c` — `WMI_REG_CHAN_LIST_CC_EVENTID`
  (~line 8917)
- `drivers/net/wireless/ath/ath11k/core.c` — board/regdb fetch logic,
  `hw_params` (`supports_regdb`, `current_cc_support` on WCN6855 hw2.1)
- `drivers/net/wireless/ath/ath11k/hw.h` — `ATH11K_REGDB_FILE_NAME =
  "regdb.bin"`, board-data IE IDs
- `net/wireless/Kconfig` — `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB` default
  patched to `n`

Local copies of tablet firmware used in analysis: `/tmp/opencode/fw/` and
the swap script `/tmp/opencode/fw10.sh`.