#!/usr/bin/env python3
"""parse / rebuild board-2.bin for ath11k (API v2 "board-2.bin").

Usage:
  bdftool.py list board-2.bin              # list name -> size
  bdftool.py md5s board-2.bin              # list name -> size md5
  bdftool.py dump board-2.bin NAME.bin NAME
  bdftool.py swap board-2.bin OUT.bin NAME PAYLOAD.bin [NAME2 PAYLOAD2.bin ...]
      Replaces the payload of the entry matching NAME (exact) or the base
      (non-variant) name with the given payload file. All other entries
      preserved byte-for-byte.
"""
import struct
import sys

MAGIC = b"QCA-ATH11K-BOARD\x00"


def align4(n):
    return (n + 3) & ~3


def parse(path):
    data = open(path, "rb").read()
    magic_len = align4(len(MAGIC))
    assert data[:len(MAGIC)] == MAGIC, "bad magic"
    raw_header = data[:magic_len]
    buf = data[magic_len:]
    top = []  # list of (ie_id, sub_entries), sub_entries = list of (sid, body)
    while len(buf) > 8:
        ie_id, ie_len = struct.unpack("<II", buf[:8])
        body = buf[8:8 + ie_len]
        buf = buf[8 + align4(ie_len):]
        sub = []
        s = body
        while len(s) > 8:
            sid, slen = struct.unpack("<II", s[:8])
            sbody = s[8:8 + slen]
            s = s[8 + align4(slen):]
            sub.append((sid, sbody))
        top.append((ie_id, sub))
    return raw_header, top


def serialize(raw_header, top):
    out = bytearray(raw_header)
    for ie_id, sub in top:
        body = bytearray()
        for sid, sbody in sub:
            body += struct.pack("<II", sid, len(sbody))
            body += sbody
            body += b"\x00" * (align4(len(sbody)) - len(sbody))
        out += struct.pack("<II", ie_id, len(body))
        out += body
        out += b"\x00" * (align4(len(body)) - len(body))
    return bytes(out)


def sub_to_name(sub):
    for sid, sbody in sub:
        if sid == 0:
            try:
                return sbody.decode("ascii")
            except Exception:
                return repr(sbody)
    return None


def sub_to_data(sub):
    for sid, sbody in sub:
        if sid == 1:
            return sbody
    return None


def main():
    cmd = sys.argv[1]

    if cmd == "list":
        _, top = parse(sys.argv[2])
        for iid, sub in top:
            name = sub_to_name(sub)
            data = sub_to_data(sub)
            if name and data:
                print(f"{len(data):7d}  {name}")

    elif cmd == "md5s":
        import hashlib
        _, top = parse(sys.argv[2])
        for iid, sub in top:
            name = sub_to_name(sub)
            data = sub_to_data(sub)
            if name and data:
                print(f"{len(data):7d} {hashlib.md5(data).hexdigest()}  {name}")

    elif cmd == "dump":
        _, top = parse(sys.argv[2])
        for iid, sub in top:
            name = sub_to_name(sub)
            data = sub_to_data(sub)
            if name == sys.argv[3] and data:
                open(sys.argv[4], "wb").write(data)
                print(f"wrote {len(data)} bytes -> {sys.argv[4]}")
                return
        sys.exit(f"entry {sys.argv[3]!r} not found")

    elif cmd == "swap":
        src, out, *pairs = sys.argv[2:]
        raw_header, top = parse(src)
        swaps = [(pairs[i], pairs[i + 1]) for i in range(0, len(pairs), 2)]
        n = 0
        for iid, sub in top:
            name = sub_to_name(sub)
            if name is None:
                continue
            for target, path in swaps:
                if name == target or name.split(",variant=")[0] == target:
                    payload = open(path, "rb").read()
                    new_sub = []
                    for sid, sbody in sub:
                        if sid == 1:
                            sbody = payload
                        new_sub.append((sid, sbody))
                    sub[:] = new_sub
                    n += 1
                    print(f"swapped {name} <- {path} ({len(payload)} B)")
        if not n:
            sys.exit("no entries matched")
        out_bytes = serialize(raw_header, top)
        open(out, "wb").write(out_bytes)
        print(f"wrote {out_bytes} bytes -> {out}")


if __name__ == "__main__":
    main()