#!/bin/bash
# Build the app and publish a GitHub release for the given commit.
#
# Normally invoked by scripts/git-hooks/pre-push on a push to main:
#   1. builds and zips the app NOW (a broken build aborts the push)
#   2. publishes tag + release in the background once the commit is visible
#      on origin/main (a pre-push hook runs before the commit reaches GitHub)
#
# Manual use: scripts/release.sh [sha]     (defaults to HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."

SHA="${1:-$(git rev-parse HEAD)}"
BASE="$(cat VERSION 2>/dev/null || echo 1.0)"
VERSION="$BASE.$(git rev-list --count "$SHA")"
TAG="v$VERSION"

if ! command -v gh >/dev/null 2>&1; then
  echo "release: gh CLI not installed — skipping release $TAG" >&2
  exit 0
fi
if gh release view "$TAG" --json tagName >/dev/null 2>&1; then
  echo "release: $TAG already exists — nothing to do"
  exit 0
fi

echo "==> Release $TAG — building"
APP_VERSION="$VERSION" ./build.sh

ZIP="dist/SecretsVault-$VERSION.zip"
SUM="$ZIP.sha256"
rm -f "$ZIP" "$SUM"
ditto -c -k --keepParent "dist/Secrets Vault.app" "$ZIP"
# Published next to the zip. The in-app updater refuses to install a download
# that does not match it (see UpdateService / CodeSignature in the app).
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$SUM")")

# Release notes: commit subjects since the previous release tag.
PREV="$(git describe --tags --abbrev=0 "$SHA^" 2>/dev/null || true)"
RANGE="$SHA"; [ -n "$PREV" ] && RANGE="$PREV..$SHA"
NOTES="$(git log --pretty='- %s' "$RANGE" | head -50)"
[ -n "$NOTES" ] || NOTES="Automated release."

LOG="dist/release-$TAG.log"
echo "==> Release $TAG — will publish in background once $SHA is on origin/main"
echo "    log: $LOG"
(
  ok=""
  for _ in $(seq 1 60); do
    git fetch origin main >/dev/null 2>&1 || true
    if git merge-base --is-ancestor "$SHA" origin/main 2>/dev/null; then ok=1; break; fi
    sleep 2
  done
  if [ -z "$ok" ]; then
    echo "release: $SHA never appeared on origin/main after 2 minutes — giving up."
    echo "release: publish manually with: scripts/release.sh $SHA"
    exit 1
  fi
  gh release create "$TAG" "$ZIP" "$SUM" \
    --target "$SHA" \
    --title "Secrets Vault $VERSION" \
    --notes "$NOTES"
  echo "release: published $TAG"
) </dev/null >"$LOG" 2>&1 &
disown 2>/dev/null || true
echo "==> Release $TAG queued"
