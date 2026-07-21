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

# Embed a pre-extracted kernelcache for a 100% offline, no-VPN install.
# Obtain it with fetch_kernelcache.py (or copy one in manually) and place it at
# Resources/kernelcache. If absent, the app falls back to the configured mirror
# (KernelcacheSource.mirrorBaseURL) and finally to Apple's servers.
if [ -f Resources/kernelcache ]; then
  cp Resources/kernelcache "$APP_DIR/$SCHEME.app/kernelcache"
  echo "-> Embedded Resources/kernelcache (offline install enabled)"
else
  echo "-> No Resources/kernelcache found; will use mirror/Apple at runtime"
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
