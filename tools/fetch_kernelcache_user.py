#!/usr/bin/env python3
"""
Fetch & extract a device-specific LZFSE kernelcache for OFFLINE TrollStore install.

How it works (no hard-coded URLs needed):
  1. Query Apple's public asset feed  https://gdmf.apple.com/v2/assets
  2. Locate the restore IPSW for the given device + build
  3. Download ONLY the kernelcache entry from the IPSW (HTTP Range requests)
  4. Save it as an LZFSE file (magic `bvx2`) ready for TrollInstallerX's getKernel()

This only needs access to Apple's servers (updates.cdn-apple.com / gdmf.apple.com) —
which works fine in China WITHOUT a VPN. Run it on your Mac/Windows before building,
or let GitHub Actions run it at build time (Actions runners have internet).

Usage:
  python3 fetch_kernelcache_user.py                            # default: iPhone8,1 15.8.7 (19H384)
  python3 fetch_kernelcache_user.py --device iPhone14,2 --version 16.5.1 --build 20F75
  python3 fetch_kernelcache_user.py --url <direct .ipsw link>  # skip feed lookup
"""
import urllib.request, struct, os, sys, json, argparse

GDMF = "https://gdmf.apple.com/v2/assets"


def log(m):
    print("[kc]", m)


def range_req(url, start, end=None, timeout=180):
    headers = {
        "Range": "bytes={}-{}".format(start, end if end is not None else ""),
        "User-Agent": "TrollInstallerX-novpn/4.0",
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except Exception as e:
        log("Range error: {}".format(e))
        return None


def resolve_ipsw_url(device, build):
    log("Querying Apple asset feed for {} {} ...".format(device, build))
    try:
        req = urllib.request.Request(GDMF, headers={"User-Agent": "TrollInstallerX-novpn/4.0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        log("Failed to fetch asset feed: {}".format(e))
        return None
    for asset in data.get("Assets", []):
        if asset.get("Build") != build:
            continue
        if device not in asset.get("SupportedDevices", []):
            continue
        restore = asset.get("Restore") or {}
        url = restore.get("URL")
        if url and url.endswith(".ipsw"):
            log("Found IPSW: {}".format(url))
            return url
    log("No matching IPSW found for {} {}".format(device, build))
    return None


def find_kernelcache_in_ipsw(ipsw_url, out_path):
    # Grab the tail of the IPSW to locate the ZIP64 EOCD record (no need to know total size).
    tail = range_req(ipsw_url, -200000)
    if not tail or len(tail) < 100:
        log("Failed to read IPSW tail")
        return 1
    loc_pos = tail.rfind(b"PK\x06\x07")
    if loc_pos < 0:
        log("No ZIP64 EOCD locator found")
        return 1
    eocd64_offset = struct.unpack_from("<Q", tail, loc_pos + 8)[0]
    eocd64_data = range_req(ipsw_url, eocd64_offset, eocd64_offset + 200)
    if not eocd64_data or eocd64_data[:4] != b"PK\x06\x06":
        log("Bad ZIP64 EOCD record")
        return 1
    cd_size = struct.unpack_from("<Q", eocd64_data, 40)[0]
    cd_offset = struct.unpack_from("<Q", eocd64_data, 48)[0]
    log("Central dir @ 0x{:x} size 0x{:x}".format(cd_offset, cd_size))
    cd_data = range_req(ipsw_url, cd_offset, cd_offset + cd_size)
    if not cd_data:
        log("Failed to read central directory")
        return 2

    pos = 0
    kc = None
    while pos + 46 <= len(cd_data):
        if cd_data[pos:pos + 4] != b"PK\x01\x02":
            break
        comp_method = struct.unpack_from("<H", cd_data, pos + 10)[0]
        comp_size = struct.unpack_from("<I", cd_data, pos + 20)[0]
        uncomp_size = struct.unpack_from("<I", cd_data, pos + 24)[0]
        name_len = struct.unpack_from("<H", cd_data, pos + 28)[0]
        extra_len = struct.unpack_from("<H", cd_data, pos + 30)[0]
        comment_len = struct.unpack_from("<H", cd_data, pos + 32)[0]
        local_off = struct.unpack_from("<I", cd_data, pos + 42)[0]
        name_raw = cd_data[pos + 44:pos + 44 + name_len]
        extra = cd_data[pos + 44 + name_len:pos + 44 + name_len + extra_len]

        if comp_size == 0xFFFFFFFF or uncomp_size == 0xFFFFFFFF or local_off == 0xFFFFFFFF:
            ep = 0
            while ep + 4 <= len(extra):
                tag = struct.unpack_from("<H", extra, ep)[0]
                esz = struct.unpack_from("<H", extra, ep + 2)[0]
                if tag == 0x0001 and esz >= 28:  # ZIP64 extended info
                    o = ep + 4
                    if uncomp_size == 0xFFFFFFFF:
                        uncomp_size = struct.unpack_from("<Q", extra, o)[0]; o += 8
                    if comp_size == 0xFFFFFFFF:
                        comp_size = struct.unpack_from("<Q", extra, o)[0]; o += 8
                    if local_off == 0xFFFFFFFF:
                        local_off = struct.unpack_from("<Q", extra, o)[0]
                    break
                ep += 4 + esz

        if b"kernelcache" in name_raw.lower():
            kc = {
                "name": name_raw.decode("utf-8", "replace"),
                "comp_size": comp_size,
                "local_off": local_off,
                "nl": name_len,
                "el": extra_len,
            }
            break
        pos += 46 + name_len + extra_len + comment_len

    if not kc:
        log("kernelcache entry not found in IPSW")
        return 2
    log("Found {} (compressed {:,} bytes)".format(kc["name"], kc["comp_size"]))
    data_start = kc["local_off"] + 30 + kc["nl"] + kc["el"]
    data_end = data_start + kc["comp_size"]
    raw = range_req(ipsw_url, data_start, data_end)
    if not raw or len(raw) < 1000:
        log("Download failed (got {} bytes)".format(len(raw) if raw else 0))
        return 3
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(raw)
    log("Saved kernelcache -> {} ({:,} bytes = {:.1f} MB)".format(
        out_path, len(raw), len(raw) / 1024 / 1024))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="iPhone8,1")
    ap.add_argument("--version", default="15.8.7")
    ap.add_argument("--build", default="19H384")
    ap.add_argument("--out", default=None)
    ap.add_argument("--url", default=None, help="Direct .ipsw URL (skip feed lookup)")
    args = ap.parse_args()

    out = args.out or "kernelcaches/{}_{}/kernelcache".format(args.device, args.version)
    if os.path.exists(out):
        log("{} already exists — skipping (delete to re-fetch)".format(out))
        return 0

    url = args.url or resolve_ipsw_url(args.device, args.build)
    if not url:
        log("Could not resolve IPSW URL. If Apple's feed is blocked, pass --url <direct .ipsw link>.")
        return 4
    return find_kernelcache_in_ipsw(url, out)


if __name__ == "__main__":
    sys.exit(main())
