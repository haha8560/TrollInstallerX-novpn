#!/usr/bin/env bash
#
# Build TrollInstallerX (no-VPN fork) into a sideloadable IPA.
#
# What this does:
#   1. xcodebuild (CODE_SIGNING_ALLOWED=NO) -> unsigned .app
#   2. Optionally embeds Resources/kernelcache (fully offline / no-VPN install)
#   3. Fake-signs with Resources/ents.plist (ldid if present, else built-in codesign)
#   4. Zips into TrollInstallerX.ipa
#
# Requirements: macOS + Xcode command line tools. `brew install ldid` optional.
# The produced IPA is unsigned/ad-hoc and is meant to be installed with
# AltStore / Sideloadly using a free Apple ID (7-day re-sign).

set -e
cd "$(dirname "$0")"

: "${SCHEME:=TrollInstallerX}"
: "${CONFIG:=Release}"

# --- v17: re-sign the patched PersistenceHelper (offline-install build) ---
# Patching the GitHub URL inside __TEXT invalidates the Mach-O code signature.
# An invalid signature makes the kernel kill Tips on launch (the v16 crash).
# Re-sign it ad-hoc here, preserving the original entitlements, so the binary
# is valid again and launches exactly like the stock opa334 helper (which is
# itself ad-hoc signed).
if [ -f Resources/TrollStore.tar ]; then
  TMPD=$(mktemp -d)
  tar xf Resources/TrollStore.tar -C "$TMPD"
  PH="$TMPD/TrollStore.app/PersistenceHelper"
  if [ -f "$PH" ]; then
    ENT="$TMPD/ph_ent.xml"
    if command -v ldid >/dev/null 2>&1; then
      ldid -e "$PH" > "$ENT" 2>/dev/null || true
      if [ -s "$ENT" ]; then
        ldid -S"$ENT" "$PH"
      else
        ldid -S "$PH"
      fi
      echo "-> Re-signed patched PersistenceHelper via ldid (offline-install fix)"
    elif command -v codesign >/dev/null 2>&1; then
      codesign -d --entitlements "$ENT" - "$PH" >/dev/null 2>&1 || true
      if [ -s "$ENT" ]; then
        codesign --force --entitlements "$ENT" -s - "$PH"
      else
        codesign --force -s - "$PH"
      fi
      echo "-> Re-signed patched PersistenceHelper via codesign (offline-install fix)"
    else
      echo "!! WARNING: no codesigning tool available; patched PersistenceHelper left unsigned (Tips will crash on launch)"
    fi
    tar cf Resources/TrollStore.tar -C "$TMPD" TrollStore.app
  fi
  rm -rf "$TMPD"
fi

xcodebuild -configuration "$CONFIG" \
  -derivedDataPath DerivedData/"$SCHEME" \
  -destination 'generic/platform=iOS' \
  -scheme "$SCHEME" \
  CODE_SIGNING_ALLOWED="NO" \
  CODE_SIGNING_REQUIRED="NO" \
  CODE_SIGN_IDENTITY=""

APP_DIR="DerivedData/$SCHEME/Build/Products/$CONFIG-iphoneos"
cp Resources/ents.plist "$APP_DIR/"

# v12: embed MULTIPLE per-device kernelcaches for 100% offline install.
#
# Place an LZFSE-compressed kernelcache at:  kernelcaches/<Model>_<Version>/kernelcache
#   e.g.  kernelcaches/iPhone8,1_15.8.7/kernelcache
#         kernelcaches/iPhone14,2_16.5.1/kernelcache
# build.sh copies each into the app bundle as:  kernelcache_<ModelU>_<Version>.lzfse
# (commas in the model are replaced with underscores, e.g. kernelcache_iPhone14_2_16.5.1).
#
# The app's getKernel() picks the matching file by device model + iOS version, so a
# single IPA can install offline on EVERY bundled device/version combo.
#
# Best-effort auto-fetch: if a kernelcache is missing, try downloading it from Apple's
# CDN (works on GitHub Actions runners, which have internet, and on your own machine).
# This makes the offline IPA buildable even if the file wasn't committed beforehand.

# Devices we want baked in (device:version:build). Edit to add more models.
FETCH_DEVICES=("iPhone8,1:15.8.7:19H384" "iPhone14,2:16.5.1:20F75")
if command -v python3 >/dev/null 2>&1 && [ -f tools/fetch_kernelcache_user.py ]; then
  for spec in "${FETCH_DEVICES[@]}"; do
    IFS=':' read -r m v b <<< "$spec"
    dstdir="kernelcaches/${m}_${v}"
    if [ ! -f "$dstdir/kernelcache" ]; then
      echo "-> Auto-fetching kernelcache for ${m} ${v} (${b}) ..."
      python3 tools/fetch_kernelcache_user.py --device "$m" --version "$v" --build "$b" \
        --out "$dstdir/kernelcache" \
        || echo "   (fetch failed — that device will fall back to network at runtime)"
    fi
  done
fi

EMBEDDED_COUNT=0
for kc in kernelcaches/*/kernelcache; do
  [ -f "$kc" ] || continue
  MODEL_DIR=$(dirname "$kc")
  NAME=$(basename "$MODEL_DIR")            # e.g. iPhone14,2_16.5.1
  NAME=${NAME//,/_}                        # iPhone14_2_16.5.1
  cp "$kc" "$APP_DIR/$SCHEME.app/kernelcache_${NAME}.lzfse"
  echo "-> Embedded $kc as kernelcache_${NAME}.lzfse (offline for $NAME)"
  EMBEDDED_COUNT=$((EMBEDDED_COUNT + 1))
done
if [ "$EMBEDDED_COUNT" -gt 0 ]; then
  echo "-> Total: $EMBEDDED_COUNT kernelcache(s) embedded (fully offline for those devices)"
else
  echo "-> No kernelcaches found — installer will need network/mirror at runtime"
fi

pushd "$APP_DIR" >/dev/null
rm -rf Payload "$SCHEME.ipa"
mkdir Payload
cp -r "$SCHEME.app" Payload

if command -v ldid >/dev/null 2>&1; then
  ldid -Sents.plist Payload/"$SCHEME.app"
  echo "-> Signed with ldid"
else
  codesign --force --entitlements ents.plist -s - Payload/"$SCHEME.app"
  echo "-> Signed ad-hoc with codesign (entitlements embedded)"
fi

zip -qry "$SCHEME.ipa" Payload
popd >/dev/null

cp "$APP_DIR/$SCHEME.ipa" .
echo "Built $SCHEME.ipa ($(du -h "$SCHEME.ipa" | cut -f1))"
