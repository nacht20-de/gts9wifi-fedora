#!/bin/bash
# Minimal pre-root USB gadget network: lets the host ping the tablet during
# initramfs, proving the kernel + initramfs reached userspace even when the
# root mount then fails.  (The pmOS initramfs did the same, plus a shell.)
check() { return 0; }
depends() { return 0; }
install() {
    inst_binary /usr/sbin/ip
    inst_hook cmdline 90 "$moddir/usbnet.sh"
}
