#!/usr/bin/env python3
"""
fetch_kernelcache.py - download & extract a (decompressed) kernelcache for a
specific device/iOS version, so it can be embedded into the app bundle for a
100% offline, no-VPN TrollStore install.

Output is written to Resources/kernelcache (no extension) which build.sh copies
into the .app. At runtime, TrollInstallerX's getKernel() uses the embedded file
first and never touches the network.

Usage:
    python3 fetch_kernelcache.py --model iPhone14,2 --version 15.1
    python3 fetch_kernelcache.py --model iPhone14,2 --version 15.8.8 --build 22G250
    python3 fetch_kernelcache.py --boardconfig D16AP   --version 15.1

Notes:
    * Requires network access to AppleDB (api.appledb.dev) and Apple's CDN.
    * Extraction uses pyimg4 + lzfse. Install deps into a venv automatically.
    * If extraction fails on your machine, you can instead grab a kernelcache
      from any working TrollStore installer's bundle, or use the runtime mirror
      (KernelcacheSource.mirrorBaseURL) which needs no embedded file at all.
"""
import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

APPLEDB = "https://api.appledb.dev/device/{}.json"

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "Resources", "kernelcache")


def log(m):
    print("[fetch_kernelcache]", m)


def ensure_deps():
    venv = os.path.join(ROOT, ".venv")
    if not os.path.isdir(venv):
        subprocess.check_call([sys.executable, "-m", "venv", venv])
    pip = os.path.join(venv, "bin", "pip") if os.name != "nt" else os.path.join(venv, "Scripts", "pip.exe")
    subprocess.check_call([pip, "install", "--quiet", "pyimg4", "lzfse", "requests"])
    return venv


def load_mod(modname, venv):
    # import from the venv by manipulating sys.path
    site = subprocess.check_output(
        [os.path.join(venv, "bin", "python") if os.name != "nt" else os.path.join(venv, "Scripts", "python.exe"),
         "-c", "import site,sys; print(site.getsitepackages()[0])"]).decode().strip()
    sys.path.insert(0, site)
    return __import__(modname)


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "TrollInstallerX-novpn"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def resolve_boardconfig(device_json, model):
    # AppleDB device JSON has 'boardconfig' and a 'devices' list of models.
    bc = device_json.get("boardconfig")
    if bc:
        return bc
    # try to find a firmware list keys
    return None


def find_firmware(device_json, version, build):
    for fw in device_json.get("firmwares", []):
        ident = str(fw.get("identifier", ""))
        bid = str(fw.get("buildid", ""))
        if (version and ident == version) or (build and bid == build):
            return fw
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="e.g. iPhone14,2")
    ap.add_argument("--boardconfig", help="e.g. D16AP (takes precedence over --model)")
    ap.add_argument("--version", required=True, help="e.g. 15.1 or 15.8.8")
    ap.add_argument("--build", help="e.g. 19B74 (more precise than version)")
    ap.add_argument("--output", default=OUT)
    args = ap.parse_args()

    venv = ensure_deps()
    pyimg4 = load_mod("pyimg4", venv)
    import lzfse  # noqa

    ident = args.boardconfig or args.model
    if not ident:
        log("ERROR: provide --model or --boardconfig")
        sys.exit(2)

    log(f"Querying AppleDB for {ident} ...")
    try:
        dj = fetch_json(APPLEDB.format(ident))
    except Exception as e:
        # try without comma
        alt = ident.replace(",", "")
        log(f"  primary failed ({e}); trying {alt}")
        dj = fetch_json(APPLEDB.format(alt))

    fw = find_firmware(dj, args.version, args.build)
    if not fw:
        log(f"ERROR: no firmware matching version={args.version} build={args.build}")
        sys.exit(3)

    url = (fw.get("ota") or fw.get("restore") or {}).get("url")
    if not url:
        log("ERROR: firmware has no ota/restore url")
        sys.exit(3)
    log(f"Found {fw.get('identifier')} ({fw.get('buildid')}) -> {url}")

    boardconfig = resolve_boardconfig(dj, args.model) or args.boardconfig or ""
    log(f"Boardconfig: {boardconfig or 'unknown'}")

    with tempfile.TemporaryDirectory() as td:
        zip_path = os.path.join(td, "fw.zip")
        log("Downloading firmware (this can be large)...")
        urllib.request.urlretrieve(url, zip_path)
        log("Extracting...")
        with zipfile.ZipFile(zip_path) as z:
            names = z.namelist()
            # kernelcache file: contains 'kernelcache' and the boardconfig
            cand = [n for n in names if "kernelcache" in n.lower()]
            if boardconfig:
                cand = [n for n in cand if boardconfig.lower() in n.lower()] or cand
            if not cand:
                log(f"ERROR: no kernelcache file in archive. Files: {names[:20]}")
                sys.exit(4)
            kc_name = cand[0]
            log(f"kernelcache entry: {kc_name}")
            raw = z.read(kc_name)

        log("Decoding IMG4 + decompressing...")
        img4 = pyimg4.IMG4(file=raw)
        im4p = img4.payload
        data = im4p.data
        comp = getattr(im4p, "compression", "none")
        if comp in ("lzfse",):
            data = lzfse.decompress(data)
        elif comp in ("lzss",):
            # lzss needs a decoder; pyimg4 may expose one
            try:
                data = pyimg4.decompress_lzss(data)
            except Exception:
                log("WARN: lzss decompression unavailable; writing compressed blob (may not work)")
        else:
            log(f"compression={comp}; writing as-is")

        os.makedirs(os.path.dirname(args.output), exist_ok=True)
        with open(args.output, "wb") as f:
            f.write(data)
        log(f"WROTE {args.output} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
