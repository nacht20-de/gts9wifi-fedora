#!/usr/bin/env python3
"""Extract and validate the compressed kernel from an arm64 EFI zboot image."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import struct
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    image = args.source.read_bytes()
    if len(image) < 64 or image[:2] != b"MZ" or image[4:8] != b"zimg":
        raise SystemExit("input is not an arm64 EFI zboot image")

    offset, size = struct.unpack_from("<II", image, 8)
    compression = image[24:32].split(b"\0", 1)[0]
    if compression != b"gzip":
        raise SystemExit(f"unsupported zboot compression: {compression!r}")
    if offset < 64 or size == 0 or offset + size > len(image):
        raise SystemExit("invalid zboot payload bounds")

    payload = image[offset : offset + size]
    if payload[:3] != b"\x1f\x8b\x08":
        raise SystemExit("zboot payload is not gzip")
    kernel = gzip.decompress(payload)
    if len(kernel) < 64 or kernel[0x38:0x3C] != b"ARMd":
        raise SystemExit("payload does not contain a valid arm64 Linux Image")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    print(
        f"{hashlib.sha256(payload).hexdigest()}  {args.output} "
        f"({len(payload)} bytes; uncompressed {len(kernel)} bytes)"
    )


if __name__ == "__main__":
    main()
