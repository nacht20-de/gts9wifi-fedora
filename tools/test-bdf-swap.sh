#!/bin/bash
# test-bdf.sh <candidate board-2.bin>
# Swaps the active board-2.bin, reloads ath11k, waits for Wi-Fi, scans for
# the 5 GHz AP, records the RSSI, then restores the ORIGINAL BDF and reloads.
# Logs to /tmp/bdf-test.log and appends "RESULT <rssi> <candidate>" to
# /tmp/bdf-test-results.txt
set -u

BDPATH=/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin
LOG=/tmp/bdf-test.log
RESULTS=/tmp/bdf-test-results.txt
CAND="$1"
AP_FREQ=5180
AP_BSSID=8c:15:c7:ef:d7:fa

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

# trailing single quote in stored ORIGINAL
ORIG_FILE="$BDPATH.orig-baseline"
cp "$BDPATH" /tmp/bdf-orig.bin.$$
md5orig=$(md5sum /tmp/bdf-orig.bin.$$ | awk '{print $1}')
md5cand=$(md5sum "$CAND" | awk '{print $1}')
log "start candidate=$CAND md5cand=$md5cand origmd5=$md5orig"

install() {
    cp "$1" "$BDPATH"
    sync
    md5sum "$BDPATH" >> "$LOG"
    RESTOREMD5=$(md5sum "$1" | awk '{print $1}')
    # make sure the target placeholder was actually replaced
    ACTUAL=$(md5sum "$BDPATH" | awk '{print $1}')
    if [ "$ACTUAL" != "$RESTOREMD5" ]; then
        log "ERROR: board-2.bin not installed correctly ($ACTUAL != $RESTOREMD5)"
        return 1
    fi
    return 0
}

reload_wifi() {
    log "reloading ath11k modules"
    echo fedora | sudo -S rmmod ath11k_pci 2>>"$LOG"
    echo fedora | sudo -S modprobe ath11k_pci 2>>"$LOG"
    sleep 2
}

wait_wifi_scan() {
    # wait up to 60s for wlp1s0 to exist and be up
    for i in $(seq 1 60); do
        if ip link show wlp1s0 up >/dev/null 2>&1; then
            sleep 8
            log "wlp1s0 up after ${i} tries"
            return 0
        fi
        sleep 1
    done
    log "WARNING: wlp1s0 never came up"
    return 1
}

scan_5g() {
    # returns the signal for the BSSID on AP_FREQ
    echo fedora | sudo -S iw dev wlp1s0 scan 2>/dev/null | awk -v freq="$AP_FREQ" -v bssid="$AP_BSSID" '
        /^BSS /{cur=$0}
        /freq:/{thisfreq = ($2+0 == freq)}
        thisfreq && /signal:/{print $2; exit}
    ' | sed 's/dBm//'
}

CANDIDATE_LABEL=$(basename "$CAND")

# 1. install candidate
if ! install "$CAND"; then
    cp /tmp/bdf-orig.bin.$$ "$BDPATH"; sync
    rm -f /tmp/bdf-orig.bin.$$
    exit 1
fi

reload_wifi
wait_wifi_scan

# systematic: drop everything NM might do, take direct scan readings
sleep 15
RSSI_1=$(scan_5g)
sleep 5
RSSI_2=$(scan_5g)
sleep 5
RSSI_3=$(scan_5g)
log "candidate=$CANDIDATE_LABEL rssi_readings='$RSSI_1' '$RSSI_2' '$RSSI_3'"

# 2. restore original
if ! install /tmp/bdf-orig.bin.$$; then
    log "FATAL: could not restore original BDF"
    exit 2
fi
reload_wifi
wait_wifi_scan
sleep 20

# final check scan
RSSI_FINAL=$(scan_5g)
log "after-restore rssi='$RSSI_FINAL'"

echo "RESULT candidate=$CANDIDATE_LABEL rssi1=$RSSI_1 rssi2=$RSSI_2 rssi3=$RSSI_3 restore_rssi=$RSSI_FINAL" >> "$RESULTS"
rm -f /tmp/bdf-orig.bin.$$
log "done"