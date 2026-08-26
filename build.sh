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

# Version stamp — read by the in-app updater. Releases use <VERSION file>.<commit
# count> (see scripts/release.sh); override with APP_VERSION=x.y.z ./build.sh
BASE="$(cat VERSION 2>/dev/null || echo 1.0)"
VERSION="${APP_VERSION:-$BASE.$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION##*.}" "$APP/Contents/Info.plist"
echo "==> Version: $VERSION"

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

# Code signing. Preference order:
#   1. $CODESIGN_IDENTITY if set ("adhoc" forces ad-hoc signing)
#   2. auto-detected "Developer ID Application" identity
#   3. auto-detected "Apple Development" identity
#   4. ad-hoc
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ "$IDENTITY" = "adhoc" ]; then
  IDENTITY=""
elif [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development/ {print $2; exit}')
  fi
fi

if [ -n "$IDENTITY" ]; then
  case "$IDENTITY" in
    "Developer ID"*) TSFLAG="--timestamp" ;;
    *)               TSFLAG="--timestamp=none" ;;
  esac
  echo "==> Code signing with: $IDENTITY (hardened runtime)"
  if ! codesign --force --options runtime "$TSFLAG" --sign "$IDENTITY" "$APP"; then
    echo "    real signing failed — falling back to ad-hoc"
    codesign --force --sign - "$APP"
  fi
else
  echo "==> Code signing (ad-hoc). Set CODESIGN_IDENTITY or add a signing"
  echo "    certificate in Xcode for a stable signature across rebuilds."
  codesign --force --sign - "$APP"
fi

echo "==> Done: $APP"
