#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building SecretsVault (release)"
swift build -c release

APP="dist/Secrets Vault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SecretsVault "$APP/Contents/MacOS/SecretsVault"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon (generated once, then reused)
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> Generating app icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  if swift scripts/makeicon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns; then
    echo "    icon written to Resources/AppIcon.icns"
  else
    echo "    (icon generation failed — continuing without custom icon)"
  fi
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Code signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
