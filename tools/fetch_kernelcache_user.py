#!/usr/bin/env python3
"""
Fetch & extract a device-specific LZFSE kernelcache for OFFLINE TrollStore install.

How it works (no hard-coded IPSW URLs needed):
  1. Resolve the firmware for the given build via AppleDB (https://api.appledb.dev/ios/<build>.json)
     -> it returns both a "restore" (.ipsw) URL and an "ota" URL.
  2a. If a restore IPSW exists (e.g. 16.5.1): download ONLY the kernelcache entry via HTTP
      Range requests, extract the LZFSE payload from the IMG4/im4p container, save it.
  2b. If only an OTA exists (e.g. 15.8.7 / 15.8.8 are OTA-only security updates): download the
      OTA, unzip, locate the kernelcache entry, extract the LZFSE payload. (If the kernelcache
      is nested inside the OTA payload DMG, the script will tell you and fall back to the
      one-time-VPN-cache method described in the README.)

The output is a ready-to-embed LZFSE file (magic `bvx2`) that TrollInstallerX's getKernel()
consumes directly — no further conversion needed.

Network: needs access to Apple's servers / AppleDB. Works fine from most networks in China
without a VPN. Run it on your Mac/PC before building, or let GitHub Actions run it at build
time (Actions runners have internet).

Usage:
  python3 fetch_kernelcache_user.py --device iPhone8,1 --version 15.8.7 --build 19H384
  python3 fetch_kernelcache_user.py --device iPhone14,2 --version 16.5.1 --build 20F75
  python3 fetch_kernelcache_user.py --url <direct .ipsw or .ota link>  # skip firmware lookup
"""
import urllib.request, struct, os, sys, json, argparse, io, zipfile

GDMF = "https://gdmf.apple.com/v2/assets"
APPLEDB_IOS = "https://api.appledb.dev/ios/{build}.json"


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


def get_url(url, timeout=180):
    req = urllib.request.Request(url, headers={"User-Agent": "TrollInstallerX-novpn/4.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except Exception as e:
        log("GET error: {}".format(e))
        return None


# ---------------------------------------------------------------------------
# IMG4 / im4p -> LZFSE payload extraction (DER-accurate)
# ---------------------------------------------------------------------------
def extract_lzfse_from_im4p(data: bytes) -> bytes | None:
    """Return the LZFSE (bvx2) kernelcache payload from an IMG4 file, else None."""
    if data[:4] == b"bvx2":
        return data  # already LZFSE
    if data[:4] != b"IM4P":
        return None
    i = 4
    # skip name (null-terminated C string)
    while i < len(data) and data[i] != 0:
        i += 1
    i += 1
    if i + 8 > len(data):
        return None
    # payload type (4) + length (4)
    plen = struct.unpack_from(">I", data, i + 4)[0]
    pstart = i + 8
    payload = data[pstart:pstart + plen]
    if payload[:4] == b"bvx2":
        return payload
    # Some im4p wrap a nested IMG4 (krnl) — try to find the first LZFSE blob.
    idx = payload.find(b"bvx2")
    if idx >= 0:
        # parse DER OCTET STRING length at idx-4
        length = struct.unpack_from(">I", payload, idx - 4)[0]
        return payload[idx:idx + length]
    return None


def save_lzfse(data: bytes, out_path: str) -> bool:
    if data[:4] != b"bvx2":
        log("Extracted payload is not LZFSE (magic=%r) — not usable" % data[:4])
        return False
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(data)
    log("Saved LZFSE kernelcache -> {} ({:,} bytes = {:.1f} MB)".format(
        out_path, len(data), len(data) / 1024 / 1024))
    return True


# ---------------------------------------------------------------------------
# Firmware resolution
# ---------------------------------------------------------------------------
def resolve_firmware(build):
    """Return (restore_url, ota_url) for the build via AppleDB."""
    log("Querying AppleDB for build {} ...".format(build))
    try:
        raw = get_url(APPLEDB_IOS.format(build=build), timeout=60)
        if not raw:
            return None, None
        j = json.loads(raw.decode("utf-8"))
    except Exception as e:
        log("AppleDB lookup failed: {}".format(e))
        return None, None
    restore = (j.get("restore") or {}).get("url")
    ota = (j.get("ota") or {}).get("url")
    if restore:
        log("restore IPSW: {}".format(restore))
    if ota:
        log("ota: {}".format(ota))
    if not restore and not ota:
        log("No restore/ota URL in AppleDB response for {}".format(build))
    return restore, ota


# ---------------------------------------------------------------------------
# IPSW path (restore build)
# ---------------------------------------------------------------------------
def find_kernelcache_in_ipsw(ipsw_url, out_path):
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
    cd_data = range_req(ipsw_url, cd_offset, cd_offset + cd_size)
    if not cd_data:
        log("Failed to read central directory")
        return 2

    pos = 0
    kc = None
    while pos + 46 <= len(cd_data):
        if cd_data[pos:pos + 4] != b"PK\x01\x02":
            break
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
                if tag == 0x0001 and esz >= 28:
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
            kc = {"name": name_raw.decode("utf-8", "replace"),
                  "comp_size": comp_size, "local_off": local_off,
                  "nl": name_len, "el": extra_len}
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
    lzfse = extract_lzfse_from_im4p(raw)
    if not lzfse:
        log("Could not extract LZFSE from {} (magic=%r)" % (kc["name"], raw[:4]))
        return 3
    return 0 if save_lzfse(lzfse, out_path) else 3


# ---------------------------------------------------------------------------
# OTA path (OTA-only build, e.g. 15.8.7 / 15.8.8)
# ---------------------------------------------------------------------------
def find_kernelcache_in_ota(ota_url, out_path):
    log("Downloading OTA (this can be ~1-2 GB) ...")
    raw = get_url(ota_url, timeout=600)
    if not raw or len(raw) < 1_000_000:
        log("Failed to download OTA (got {} bytes)".format(len(raw) if raw else 0))
        return 4
    try:
        z = zipfile.ZipFile(io.BytesIO(raw))
    except Exception as e:
        log("OTA is not a readable zip: {}".format(e))
        return 4
    # Prefer a kernelcache entry whose path mentions the device board, else any kernelcache.
    candidates = []
    for n in z.namelist():
        nl = n.lower()
        if "kernelcache" in nl and not nl.endswith(".dmg"):
            candidates.append(n)
    if not candidates:
        log("kernelcache not a direct entry in this OTA (it is inside the payload DMG).")
        log("Fallback: build the IPA, run it ONCE with a VPN -> kernelcache is cached in")
        log("the app's Documents and every later install is fully offline. See README.")
        return 5
    # Pick the shortest-named candidate (the plain kernelcache, not a manifest duplicate).
    cand = min(candidates, key=len)
    log("Found OTA kernelcache entry: {}".format(cand))
    data = z.read(cand)
    lzfse = extract_lzfse_from_im4p(data)
    if not lzfse:
        log("Could not extract LZFSE from OTA entry (magic=%r)" % data[:4])
        return 3
    return 0 if save_lzfse(lzfse, out_path) else 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="iPhone8,1")
    ap.add_argument("--version", default="15.8.7")
    ap.add_argument("--build", default="19H384")
    ap.add_argument("--out", default=None)
    ap.add_argument("--url", default=None, help="Direct .ipsw or .ota URL (skip lookup)")
    args = ap.parse_args()

    out = args.out or "kernelcaches/{}_{}/kernelcache".format(args.device, args.version)
    if os.path.exists(out):
        log("{} already exists — skipping (delete to re-fetch)".format(out))
        return 0

    if args.url:
        if args.url.endswith(".ota") or "ota" in args.url.lower():
            return find_kernelcache_in_ota(args.url, out)
        return find_kernelcache_in_ipsw(args.url, out)

    restore, ota = resolve_firmware(args.build)
    if restore:
        return find_kernelcache_in_ipsw(restore, out)
    if ota:
        return find_kernelcache_in_ota(ota, out)
    log("No firmware source found for build {}. Pass --url <direct link>.".format(args.build))
    return 4


if __name__ == "__main__":
    sys.exit(main())
