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

# v10: removed embedded kernelcache.lzfse (18MB) — was causing build_physrw
# kernel panic when the embedded build did not match the user's exact iOS build
# (e.g. 20F75 embedded but user's device on 20F66). Now uses dynamic download
# from kcache.js.appstore.top (no VPN) → AppleDB → Apple (VPN). IPA drops
# from 26MB to 8MB, matching 果粉助手 size.
#
# To temporarily re-enable offline embedding for a SPECIFIC build you trust,
# uncomment the block below and drop the LZFSE file at kernelcaches/<model>/kernelcache:
#
# if [ -f kernelcaches/iPhone14,2/kernelcache ]; then
#   cp kernelcaches/iPhone14,2/kernelcache "$APP_DIR/$SCHEME.app/kernelcache.lzfse"
#   echo "-> Embedded kernelcaches/iPhone14,2/kernelcache as kernelcache.lzfse (offline install enabled)"
# fi

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
