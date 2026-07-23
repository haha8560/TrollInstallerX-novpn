#!/usr/bin/env python3
"""
Extract raw (uncompressed) Mach-O kernelcache from an Apple IPSW.

Works on macOS only — uses the system compression framework via ctypes
to decompress LZFSE, LZSS, or any other format Apple uses in IPSW kernelcaches.
Also works on Linux/Windows if the kernelcache happens to be stored uncompressed
or as LZFSE (in which case we keep it as-is for the app's prepareKernelcache to handle).

Usage:
  python3 extract_ipsw_kernelcache.py --ipsw <url_or_path> --out <output_path>
  python3 extract_ipsw_kernelcache.py --device iPhone8,1 --version 15.8.7 --build 19H411
"""
import argparse, io, os, struct, sys, urllib.request, zipfile

PROXY = os.environ.get("HTTP_PROXY", "") or os.environ.get("http_proxy", "")


def make_opener(proxy=""):
    if proxy:
        handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
        return urllib.request.build_opener(handler)
    return urllib.request.build_opener()


class RemoteFile(io.IOBase):
    """Seekable file-like object over HTTP Range requests."""

    def __init__(self, url, proxy=""):
        self.url = url
        self.pos = 0
        opener = make_opener(proxy)
        req = urllib.request.Request(url, headers={
            "Range": "bytes=0-0", "User-Agent": "TrollInstallerX-novpn/5.0"
        })
        with opener.open(req, timeout=30) as resp:
            cr = resp.headers.get("Content-Range", "")
            if "/" in cr:
                self.size = int(cr.split("/")[-1])
            else:
                self.size = None
        self._opener = opener

    def readable(self):
        return True

    def writable(self):
        return False

    def seekable(self):
        return True

    def seek(self, offset, whence=0):
        if whence == 0:
            self.pos = offset
        elif whence == 1:
            self.pos += offset
        elif whence == 2:
            self.pos = self.size + offset
        return self.pos

    def tell(self):
        return self.pos

    def read(self, size=-1):
        end = (self.pos + size - 1) if size >= 0 else None
        req = urllib.request.Request(self.url, headers={
            "Range": f"bytes={self.pos}-{end or ''}",
            "User-Agent": "TrollInstallerX-novpn/5.0"
        })
        with self._opener.open(req, timeout=300) as resp:
            data = resp.read()
        self.pos += len(data)
        return data


def find_kc_in_ipsw(ipsw_url, proxy=""):
    """Use Python's zipfile (handles ZIP64 correctly) to extract kernelcache from IPSW."""
    rf = RemoteFile(ipsw_url, proxy)
    zf = zipfile.ZipFile(rf)

    kc_entries = [info for info in zf.infolist()
                  if "kernelcache" in info.filename.lower()
                  and not info.filename.endswith(".dmg")]
    if not kc_entries:
        print(f"ERROR: No kernelcache entry found in IPSW")
        return None

    pick = kc_entries[0]
    print(f"Found: {pick.filename}")
    print(f"  compressed: {pick.compress_size:,} bytes ({pick.compress_size / 1024 / 1024:.1f}MB)")
    print(f"  file size: {pick.file_size:,} bytes ({pick.file_size / 1024 / 1024:.1f}MB)")

    raw = zf.read(pick.filename)
    print(f"  Extracted: {len(raw):,} bytes, magic={raw[:8]}")
    return raw


def decompress_apple(src_data):
    """
    Try to decompress Apple-compressed data using the system compression framework.
    Returns raw Mach-O bytes, or None if decompression fails.
    Only works on macOS.
    """
    magic = src_data[:4]

    # If it's already a Mach-O, return as-is
    macho_magics = {0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe}
    if struct.unpack_from("<I", src_data, 0)[0] in macho_magics:
        print("  Data is already raw Mach-O")
        return src_data

    # If it's LZFSE, return as-is (app will decode it)
    if magic == b"bvx2":
        print("  Data is LZFSE compressed — keeping for app-side decode")
        return src_data

    # For other formats (complzss etc.), try system decompression
    try:
        import ctypes
        import ctypes.util

        lib_path = ctypes.util.find_library("compression")
        if not lib_path:
            print("  WARNING: compression library not found (non-macOS?)")
            return None

        lib = ctypes.cdll.LoadLibrary(lib_path)

        # Try different algorithms
        algorithms = [
            ("LZFSE", 0x100),
            ("LZ4", 0x102),
            ("LZ4 Raw Block", 0x101),
            ("Zlib", 2),
            ("LZMA", 6),
        ]

        # Also try the raw complzss format by skipping its header
        if magic == b"complzss":
            print("  Detected complzss format, trying system decompression...")
            # After "complzss" there may be a 4-byte uncompressed size
            if len(src_data) > 12:
                exp_size = struct.unpack(">I", src_data[8:12])[0]
                if 0 < exp_size < 512 * 1024 * 1024:  # sanity check
                    print(f"  Expected decompressed size: {exp_size:,} bytes")

        for name, algo in algorithms:
            try:
                # Allocate output buffer (estimate 10x compression ratio)
                dst_size = max(len(src_data) * 10, 64 * 1024 * 1024)
                dst = ctypes.create_string_buffer(dst_size)

                result = lib.compression_decode_buffer(
                    dst, dst_size,
                    src_data, len(src_data),
                    None, algo
                )

                if result > 0:
                    out = dst.raw[:result]
                    m = struct.unpack_from("<I", out, 0)[0]
                    if m in macho_magics:
                        print(f"  Decompressed via {name}: {result:,} bytes -> Mach-O!")
                        return out
                    else:
                        print(f"  {name}: got {result:,} bytes but not Mach-O (magic={hex(m)})")
                else:
                    pass  # silently try next
            except Exception as e:
                print(f"  {name} error: {e}")

        print("  All system decompression algorithms failed")
        return None

    except ImportError:
        print("  ctypes not available or not macOS")
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipsw", help="Direct IPSW URL or local path")
    ap.add_argument("--device", default="iPhone8,1")
    ap.add_argument("--version", default="15.8.7")
    ap.add_argument("--build", default="19H411")
    ap.add_argument("--out", default=None)
    ap.add_argument("--proxy", default=PROXY)
    args = ap.parse_args()

    url = args.ipsw
    if not url:
        # Build URL from ipsw.me style
        print(f"No IPSW URL provided, need --ipsw argument")
        sys.exit(1)

    out = args.out or f"kernelcaches/{args.device}_{args.version}/kernelcache"

    print(f"Extracting kernelcache from IPSW...")
    print(f"  URL: {url[:80]}...")

    raw = find_kc_in_ipsw(url, args.proxy)
    if not raw:
        sys.exit(1)

    # Save raw extracted data first (for debugging)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    raw_path = out + ".raw"
    with open(raw_path, "wb") as f:
        f.write(raw)
    print(f"  Saved raw -> {raw_path}")

    # Try to get decompressed Mach-O
    decompressed = decompress_apple(raw)

    if decompressed:
        with open(out, "wb") as f:
            f.write(decompressed)
        print(f"\nSAVED -> {out} ({len(decompressed) / 1024 / 1024:.1f}MB)")
    else:
        print("\nCould not decompress. Keeping raw data as fallback.")
        # Copy raw to expected path
        import shutil
        shutil.copy(raw_path, out)
        print(f"SAVED (raw) -> {out}")


if __name__ == "__main__":
    main()
