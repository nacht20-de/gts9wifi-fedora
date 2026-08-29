#!/bin/sh
# Bring up the RNDIS gadget early so a failing boot is still visible to the
# host (172.16.42.1 answers ping once this runs).
modprobe configfs 2>/dev/null
modprobe libcomposite 2>/dev/null
modprobe usb_f_rndis 2>/dev/null
[ -d /sys/kernel/config/usb_gadget ] || mount -t configfs configfs /sys/kernel/config 2>/dev/null
G=/sys/kernel/config/usb_gadget/g1
mkdir -p "$G/functions/rndis.usb0" "$G/configs/b.1/strings/0x409" "$G/strings/0x409" 2>/dev/null || return 0
echo "fedora-gts9wifi" > "$G/strings/0x409/serialnumber" 2>/dev/null
ln -sf "$G/functions/rndis.usb0" "$G/configs/b.1" 2>/dev/null
UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null
sleep 1
ip link set usb0 up 2>/dev/null
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null
