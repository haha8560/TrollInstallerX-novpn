#!/usr/bin/env python3
"""
Extract the LZFSE-compressed kernelcache payload from an Apple IMG4 (.im4p) file.

The IMG4 `krnl` payload is an ASN.1 OCTET STRING whose content is the LZFSE
kernelcache (magic `bvx2...`). We walk the DER structure to find the `krnl`
OCTET STRING and carve out its exact content — no heuristic offsets, so trailing
IM4X signature data is never included.

No network required. Output is what TrollInstallerX's getKernel() expects:
an LZFSE file starting with `bvx2` that the app decodes to a raw Mach-O.

Usage:
    python3 extract_kernelcache_from_im4p.py <input.im4p> <output_path>
"""
import sys
import os


def _read_len(data, i):
    """Return (length, header_size) for a DER length field at offset i."""
    b = data[i]
    if b & 0x80:
        nbytes = b & 0x7F
        length = int.from_bytes(data[i + 1:i + 1 + nbytes], "big")
        return length, 1 + nbytes
    return b, 1


def _find_krnl_payload(data):
    """Walk the DER tree; return the content bytes of the `krnl` OCTET STRING."""
    stack = [(0, len(data))]
    while stack:
        start, end = stack.pop()
        i = start
        while i < end:
            tag = data[i]
            if tag in (0x30, 0x31):  # SEQUENCE / SET
                length, hs = _read_len(data, i + 1)
                content_start = i + 1 + hs
                stack.append((content_start, content_start + length))
                i = content_start + length
            elif tag == 0x04:  # OCTET STRING
                length, hs = _read_len(data, i + 1)
                content_start = i + 1 + hs
                if data[content_start:content_start + 4] == b"bvx2":
                    return data[content_start:content_start + length]
                i = content_start + length
            elif tag == 0x16:  # IA5String
                length, hs = _read_len(data, i + 1)
                i = i + 1 + hs + length
            elif tag in (0x02, 0x05, 0x01, 0x0C, 0x13, 0x0C):  # INTEGER/BOOL/UTF8/PRINTABLE
                length, hs = _read_len(data, i + 1)
                i = i + 1 + hs + length
            else:
                # Unknown tag — stop descending this branch.
                break
    return None


def extract(im4p_path: str, out_path: str) -> int:
    with open(im4p_path, "rb") as f:
        data = f.read()

    payload = _find_krnl_payload(data)
    if payload is None:
        print("[!] Could not locate a bvx2 LZFSE payload inside the IMG4")
        return 1
    if not payload.startswith(b"bvx2"):
        print("[!] Extracted payload does not start with bvx2")
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(payload)
    print(f"[+] Extracted LZFSE kernelcache -> {out_path} "
          f"({len(payload):,} bytes = {len(payload)/1024/1024:.1f} MB)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 extract_kernelcache_from_im4p.py <input.im4p> <output>")
        sys.exit(2)
    sys.exit(extract(sys.argv[1], sys.argv[2]))
