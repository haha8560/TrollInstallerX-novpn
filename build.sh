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

xcodebuild -configuration "$CONFIG" \
  -derivedDataPath DerivedData/"$SCHEME" \
  -destination 'generic/platform=iOS' \
  -scheme "$SCHEME" \
  CODE_SIGNING_ALLOWED="NO" \
  CODE_SIGNING_REQUIRED="NO" \
  CODE_SIGN_IDENTITY=""

APP_DIR="DerivedData/$SCHEME/Build/Products/$CONFIG-iphoneos"
cp Resources/ents.plist "$APP_DIR/"

# v11: optional embedded kernelcache support.
# If kernelcaches/<model>/kernelcache exists, embed as kernelcache.lzfse in the app bundle.
# This enables 100% offline installation for that specific device+version combo.
# The IPA size increases by ~17MB per embedded kernelcache.
#
# To use: place LZFSE-compressed kernelcache at kernelcaches/<model>/kernelcache
# Example: kernelcaches/iPhone8,1/kernelcache  (for iPhone 8)
#
# The app's getKernel() checks Bundle.main.path(forResource:"kernelcache", ofType:"lzfse")
# first before trying network download. No embedded file = pure network mode (8MB IPA).
EMBEDDED_COUNT=0
for kc in kernelcaches/*/kernelcache; do
  [ -f "$kc" ] || continue
  MODEL_DIR=$(dirname "$kc")
  MODEL_NAME=$(basename "$MODEL_DIR")
  cp "$kc" "$APP_DIR/$SCHEME.app/kernelcache.lzfse"
  echo "-> Embedded $kc as kernelcache.lzfse (offline install for $MODEL_NAME)"
  EMBEDDED_COUNT=$((EMBEDDED_COUNT + 1))
done
if [ "$EMBEDDED_COUNT" -gt 0 ]; then
  echo "-> Total: $EMBEDDED_COUNT kernelcache(s) embedded"
else
  echo "-> No kernelcaches found in kernelcaches/ — will use network download at runtime"
fi

# (Legacy) raw embedded kernelcache support — kept for backward compat
if [ -f Resources/kernelcache ]; then
  cp Resources/kernelcache "$APP_DIR/$SCHEME.app/kernelcache"
  echo "-> Embedded Resources/kernelcache (offline install enabled)"
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
