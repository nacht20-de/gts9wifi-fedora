#!/bin/bash
# Build the gts9wifi EL721 secure owner (rootfs/overlay/usr/libexec/
# gts9wifi-fingerprint-secure runs it).
#
# Run this ON THE TABLET: the owner is a normal aarch64 Linux binary, but it
# needs the Android-free QTEE client library built for the same machine.
#
# Inputs (all optional, defaulted to the layout the bring-up used):
#   QUIC_TEEC   quic-teec checkout, pinned to 736419e25a2036aac3292a10a93e394a90750ca3
#   PREFIX      install prefix holding lib64/libqcomtee.a and lib64/libqcbor.a
#   OUT         directory to leave el721-secure-owner in
#
# The two QTEE-side changes the owner needs are carried as
# tools/quic-teec-dmabuf-memory-object.patch: expose qcomtee_memory_object_fd()
# and add qcomtee_memory_object_register_fd() with TEE_IOC_SHM_REGISTER_FD.  The
# sibling Ultra port ships them as 0002-/0003-qcomtee-register-dmabuf.patch, but
# 0003 is malformed, so this port carries a valid replacement.
#
# The owner source itself is the vendored reference copy
# ubuntu-galaxy-tab-s9-ultra/packaging/libfprint/el721-secure-owner.c; it
# #includes el721-qtee.c, which supplies the SPL listener, the TA assembler and
# the HwVault credential restore.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
ref="$here/ubuntu-galaxy-tab-s9-ultra"
quic_teec=${QUIC_TEEC:-$HOME/fp-probe/quic-teec}
prefix=${PREFIX:-$HOME/fp-probe/prefix}
out=${OUT:-$HOME/fp-probe/fp}

[ -d "$quic_teec/libqcomtee" ] || {
    echo "no quic-teec checkout at $quic_teec" >&2; exit 1; }
[ -f "$prefix/lib64/libqcomtee.a" ] || {
    echo "no libqcomtee.a under $prefix/lib64 (build quic-teec first)" >&2; exit 1; }
[ -f "$ref/packaging/libfprint/el721-secure-owner.c" ] || {
    echo "missing the vendored reference sources under $ref" >&2; exit 1; }
pkg-config --exists glib-2.0 || {
    echo "glib-2.0 development files are required" >&2; exit 1; }

# 1. Apply the QTEE client change and rebuild it.
if ! grep -q qcomtee_memory_object_register_fd \
        "$quic_teec/libqcomtee/include/qcomtee_object_types.h"; then
    git -C "$quic_teec" apply "$here/tools/quic-teec-dmabuf-memory-object.patch"
    echo "applied the DMA-BUF memory-object patch to $quic_teec"
fi
build=${BUILD_DIR:-$HOME/fp-probe/build-qcomtee}
cmake --build "$build" -j"$(nproc)"
# The library includes <qcomtee_object_types.h> from the install prefix, so the
# header has to be installed before the library can be rebuilt.
cmake --install "$build" >/dev/null
cmake --build "$build" -j"$(nproc)"

# 2. Assemble the owner in a scratch directory: it needs <uapi/linux/spcom.h>.
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/include/uapi/linux"
cp "$ref/kernel/include/uapi/linux/spcom.h" "$work/include/uapi/linux/"
for f in el721-secure-owner.c el721-qtee.c el721-qtee.h el721-qtee-lookup.h \
         el721-enroll-wire.h el721-hwvault-wire.h el721-identify-wire.h \
         el721-spl-wire.h; do
    cp "$ref/packaging/libfprint/$f" "$work/"
done

cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -O2 \
   -I"$work/include" -I"$prefix/include" \
   "$work/el721-secure-owner.c" \
   $(pkg-config --cflags --libs glib-2.0) \
   "$prefix/lib64/libqcomtee.a" "$prefix/lib64/libqcbor.a" \
   -lpthread -o "$out/el721-secure-owner"
echo "built $out/el721-secure-owner"
