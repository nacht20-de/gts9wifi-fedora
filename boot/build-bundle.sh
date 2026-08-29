#!/bin/bash
# Build the Samsung ABL Android boot-image-v4 bundle for the Fedora port.
#
# Translated from the postmarketOS port's scripts/build-android-v4-bundle.sh,
# which physically validated every quirk encoded here:
#   - boot: kernel with appended DTB, empty cmdline (ABL forbids it here)
#   - init_boot: generic ramdisk in legacy LZ4 (gzip initramfs is rejected)
#   - vendor_boot: cmdline + bootconfig + platform ramdisk fragment
#   - dtbo: deliberately NOT an Android DT table, so ABL falls back to the
#     appended DTB
#   - vbmeta: verification disabled (flags 2); hash footers on everything
#
# Usage: build-bundle.sh --vmlinuz F --dtb F --initramfs F --cmdline F \
#                        --bootconfig F --out DIR

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

boot_size=100663296
init_boot_size=100663296
vendor_boot_size=100663296
dtbo_size=16777216
vbmeta_size=131072

while [ $# -gt 0 ]; do
    case "$1" in
        --vmlinuz) vmlinuz="$2"; shift 2 ;;
        --dtb) dtb="$2"; shift 2 ;;
        --initramfs) initramfs="$2"; shift 2 ;;
        --cmdline) cmdline_file="$2"; shift 2 ;;
        --bootconfig) bootconfig="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

for f in "$vmlinuz" "$dtb" "$initramfs" "$cmdline_file" "$bootconfig"; do
    [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
for f in "$repo/tools/mkbootimg.py" "$repo/tools/avbtool" "$repo/boot/extract-zboot-payload.py"; do
    [ -f "$f" ] || { echo "missing tool: $f" >&2; exit 1; }
done
command -v lz4 >/dev/null || { echo "lz4 not installed" >&2; exit 1; }

mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

add_hash_footer() {
    local target="$1" partition="$2" partition_size="$3" salt
    salt=$(sha256sum "$target" | cut -d' ' -f1)
    python3 "$repo/tools/avbtool" add_hash_footer \
        --image "$target" \
        --partition_name "$partition" \
        --partition_size "$partition_size" \
        --salt "$salt"
}

# The kernel builds as a zboot-wrapped Image.gz; ABL wants the raw payload.
image="$tmp/Image.gz"
python3 "$repo/boot/extract-zboot-payload.py" "$vmlinuz" "$image"

# Samsung's ABL concatenates the init_boot ramdisk with the vendor_boot
# fragments using the legacy LZ4 stream format.  A gzip initramfs is a valid
# v4 image but the kernel rejects the combined archive, so recompress.
gzip -t "$initramfs"  # we feed dracut's default gzip output
generic_ramdisk="$tmp/initramfs.lz4"
gzip -dc "$initramfs" | lz4 -l -12 - "$generic_ramdisk" >/dev/null

cmdline=$(tr '\n' ' ' < "$cmdline_file" | sed 's/[[:space:]]*$//')

# boot: kernel + appended DTB (ABL loads the DTB from here via the invalid
# dtbo fallback), no cmdline.
cat "$image" "$dtb" > "$tmp/Image.gz-dtb"
python3 "$repo/tools/mkbootimg.py" \
    --kernel "$tmp/Image.gz-dtb" \
    --cmdline '' \
    --header_version 4 \
    --os_version 13 \
    --os_patch_level 2025-07 \
    -o "$out/boot.img"
add_hash_footer "$out/boot.img" boot "$boot_size"

# init_boot: the generic (dracut) ramdisk.
python3 "$repo/tools/mkbootimg.py" \
    --ramdisk "$generic_ramdisk" \
    --header_version 4 \
    -o "$out/init_boot.img"
add_hash_footer "$out/init_boot.img" init_boot "$init_boot_size"

# vendor_boot: empty platform fragment + DTB + our cmdline + bootconfig.
mkdir -p "$tmp/empty-vendor-ramdisk"
touch -d '@0' "$tmp/empty-vendor-ramdisk"
(
    cd "$tmp/empty-vendor-ramdisk"
    find . -print0 | cpio --reproducible --null -o --format=newc 2>/dev/null
) | lz4 -l -12 - "$tmp/vendor_ramdisk.lz4" >/dev/null

python3 "$repo/tools/mkbootimg.py" \
    --ramdisk_type platform \
    --ramdisk_name '' \
    --vendor_ramdisk_fragment "$tmp/vendor_ramdisk.lz4" \
    --dtb "$dtb" \
    --vendor_cmdline "$cmdline" \
    --header_version 4 \
    --vendor_boot "$out/vendor_boot.img" \
    --base 0x80000000 \
    --kernel_offset 0x8000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --pagesize 4096 \
    --dtb_offset 0x1f00000 \
    --vendor_bootconfig "$bootconfig"
add_hash_footer "$out/vendor_boot.img" vendor_boot "$vendor_boot_size"

# dtbo: zero page, deliberately not a DT table.
rm -f "$out/dtbo.img"
truncate -s 4096 "$out/dtbo.img"
add_hash_footer "$out/dtbo.img" dtbo "$dtbo_size"

# vbmeta: disable verified boot.
python3 "$repo/tools/avbtool" make_vbmeta_image \
    --output "$out/vbmeta.img" \
    --flags 2 \
    --padding_size "$vbmeta_size"

for spec in "boot.img:$boot_size" "init_boot.img:$init_boot_size" \
            "vendor_boot.img:$vendor_boot_size" "dtbo.img:$dtbo_size" \
            "vbmeta.img:$vbmeta_size"; do
    name=${spec%%:*}; expected=${spec##*:}
    actual=$(stat -c %s "$out/$name")
    [ "$actual" -eq "$expected" ] || { echo "$name: expected $expected, got $actual" >&2; exit 1; }
done

(cd "$out" && sha256sum *.img > SHA256SUMS)
{
    printf 'kernel_sha256=%s\n' "$(sha256sum "$vmlinuz" | cut -d' ' -f1)"
    printf 'kernel_payload_sha256=%s\n' "$(sha256sum "$image" | cut -d' ' -f1)"
    printf 'dtb_sha256=%s\n' "$(sha256sum "$dtb" | cut -d' ' -f1)"
    printf 'initramfs_sha256=%s\n' "$(sha256sum "$initramfs" | cut -d' ' -f1)"
    printf 'cmdline=%s\n' "$cmdline"
} > "$out/BUILD-METADATA.txt"

echo ">>> bundle complete: $out"
ls -la "$out"
