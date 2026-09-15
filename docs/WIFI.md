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
| Firmware `amss.bin` | md5 `e38e434e815db0a1f041bc72212d9c94` — **IOE 04866.5** (`WLAN.HSP.1.1-04866.5-...-IOE-1`, `fw_version 0x11021302`), the mainline-friendly family that actually runs. Samsung's own non-LITE `amss20` image (`fd079535`) crashes ath11k with `MHI_CB_EE_RDDM`. |
| M3 `m3.bin` | md5 `75f724599b259283466e11d5adb0c3f2` — IOE family, pairs with the IOE amss |
| Board data (BDF) | `/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin` (md5 `df8157b9a251ac6c662b91df94a45438`, linux-firmware). **This is what actually gets loaded** — it has an exact `subsystem-device=0108` ABI entry for this tablet, so it overrides `board.bin` entirely. |
| Regulatory data | `regdb.bin` (24310 bytes, md5 `f67be83659c790fe15d1e42af501e9fa`, linux-firmware) + embedded regdb IE in board-2.bin (`bus=pci` fallback) |
| Regulatory mode | wiphy is **self-managed** (`phy#0 (self-managed)` in `iw reg get`) — the **firmware** decides channel flags, not cfg80211 |

### Board-data sources tried

| Source | board-2.bin md5 | Notes |
|---|---|---|
| Samsung (stock, backed up) | (original in `/lib/firmware/ath11k/samsung-backup-hw21/`) | has the per-device RF calibration entry for subsystem `17cb:0108`; ~7.2 MB |
| linux-firmware (currently installed) | `df8157b9a251ac6c662b91df94a45438` | generic WCN6855 BDF; matched entry payload is 60,036 B (md5 `0e92fa42`), distinct from every Samsung payload (58,180 B) |

The 8 Samsung BDF variants (`bdwlan{,.elf1,.elf2,.elf10}`, `bdwlang{,.elf1,.elf2,.elf10}`)
were each tested both swapped into `board.bin` **and** injected as the matched
payload inside a custom board-2.bin. Summary of what this established:

- **`board.bin` swaps are a no-op in practice.** board-2.bin has an exact ABI
  match (`bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,qmi-chip-id=18,qmi-board-id=255`)
  so the matched entry (generic 60,036 B) is loaded and `board.bin` ignored.
  All 8 `board.bin` swaps therefore produced identical Wi-Fi behavior.
- **Samsung BDF data crashes the mainline IOE firmware.** Injecting a Samsung
  BDF (e.g. `bdwlang`, 58,180 B) as the matched payload in a custom board-2.bin
  makes ath11k fail with `failed to load board data file: -2` followed by a
  firmware RDDM (`MHI_CB_EE_RDDM`) and Wi-Fi down. A custom board-2.bin
  carrying the **generic** payload (verified md5 `0e92fa42`) boots Wi-Fi
  perfectly — proving the custom container format is valid and the Samsung
  BDF *content* is what the IOE firmware rejects.

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

## ⚠️ Final state: 5 GHz RX is weak on every combination tried

The tablet **associates** on ch36 (`wpa_state=COMPLETED`) and TX is healthy,
but RX is ~50 dB below physics:

| Band | RSSI | RX bitrate | TX bitrate |
|---|---|---|---|
| 2.4 GHz (ch1) | **-28 dBm** | 52 MBit/s MCS5 | 39 MBit/s MCS10 |
| 5 GHz (ch36) | **-89 dBm** | 13.5 MBit/s VHT-MCS0 40MHz NSS1 | **351 MBit/s VHT-MCS4 80MHz NSS2** |

Same position, same router. 5 GHz TX reaches full VHT-80 NSS2 speed while RX
sits at VHT-MCS0 — a **receive-path-only deficit**, reproducible at every
BDF/firmware combination that boots at all (all 8 Samsung `board.bin`
variants, the generic board-2 matched entry, and both LITE and IOE firmware
families). Near-field test (~5 cm from the AP): 5 GHz -72…-85 dBm vs 2.4 GHz
-23 dBm → ~50 dB gap persists with no path loss involved.

### Why the Samsung BDF can't rescue it (checked exhaustively)

1. **Samsung's non-LITE `amss20` firmware** crashes mainline ath11k with
   `MHI_CB_EE_RDDM` — Samsung firmware family is unusable.
2. **Samsung BDF data injected into board-2.bin** crashes the mainline IOE
   firmware (`failed to load board data file: -2` + RDDM). A control test with
   the same custom container carrying the generic payload boots fine, so the
   Samsung *content* is incompatible — it cannot be loaded at all.
3. The only loadable 5 GHz-configuring data is the **generic** 60,036 B board
   join — and it also shows the same weak RX.

So on mainline the injectable board data is fixed to the generic BDF, and it
yields the same 5 GHz RX weakness. Combined with strong 5 GHz TX, the most
likely remaining causes are a hardware 5 GHz RX-path issue on the unit or a
firmware RX tuning quirk outside the BDF's control. To be settled definitively,
re-check the 5 GHz signal bars/speed on **Android** at the same spot (not yet
done — Android rootfs not currently loaded on the unit).

### Verified end-state (persisted)

- `amss.bin` = IOE 04866.5 (`e38e434e`) · `m3.bin` = IOE (`75f72459`)
- `regdb.bin` = linux-firmware (`f67be836`) · `board-2.bin` = linux-firmware
  generic (`df8157b9`) · `board.bin` = Samsung `e10` (`137e9438`, ignored, kept
  for fallback)
- Wi-Fi 2.4 GHz healthy; 5 GHz weak-RX limitation documented in
  [KNOWN-ISSUES.md](KNOWN-ISSUES.md) #7.

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