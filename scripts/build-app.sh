#!/usr/bin/env bash
# Builds build/Clacky.app. Pass --open to (re)launch it afterwards.
#
# Signing defaults to ad-hoc ("-"). macOS ties the Input Monitoring grant to the app's
# designated requirement, which for an ad-hoc build is a hash of that exact build, so every
# rebuild would need access granted again. Ad-hoc builds therefore get a requirement of just
# the bundle identifier, which stays the same across rebuilds. (Trade-off: any ad-hoc app
# claiming this identifier would match it. Set SIGN_IDENTITY to a real certificate to avoid that.)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Clacky.app"

swift build -c release --product Clacky
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clacky" "$APP/Contents/MacOS/Clacky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # made by scripts/make-icon.swift
cp -R "Resources/Sound Packs" "$APP/Contents/Resources/"          # the switches Clacky ships with
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
  codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x Clacky 2>/dev/null || true
  open "$APP"
fi
