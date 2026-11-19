#!/bin/bash
# Thermo installer for people without Homebrew.
# It downloads the latest release from GitHub, checks it, and installs it to /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/simarpreetsingh-019/Thermo/main/install.sh -o install.sh
#   less install.sh      # read it first: it's short
#   bash install.sh
#
# Checks before anything is installed:
#   1. SHA-256 of Thermo.zip matches the checksum published with the release
#   2. If the GitHub CLI is installed: the zip's attestation proves it was published by this repository
#   3. The app's code signature is intact and its bundle ID is Thermo's
set -euo pipefail
REPO=simarpreetsingh-019/Thermo
say() { printf '%s\n' "$*"; }
fail() { say "✗ $*"; say "  Nothing was installed."; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say "→ Finding the latest Thermo release…"
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$TAG" ] || fail "couldn't reach GitHub."
BASE="https://github.com/$REPO/releases/download/$TAG"

say "→ Downloading Thermo $TAG…"
curl -fsSL "$BASE/Thermo.zip" -o "$TMP/Thermo.zip" || fail "download failed."
curl -fsSL "$BASE/Thermo.zip.sha256" -o "$TMP/Thermo.zip.sha256" || fail "couldn't get the checksum."

EXPECTED=$(cut -d' ' -f1 "$TMP/Thermo.zip.sha256")
ACTUAL=$(shasum -a 256 "$TMP/Thermo.zip" | cut -d' ' -f1)
[ "$EXPECTED" = "$ACTUAL" ] || fail "checksum mismatch: the download doesn't match the release."
say "✓ Checksum matches the release ($ACTUAL)"

if command -v gh >/dev/null 2>&1; then
  if gh attestation verify "$TMP/Thermo.zip" --repo "$REPO" >/dev/null 2>&1; then
    say "✓ GitHub attestation: published by $REPO"
  else
    say "• GitHub attestation not checked (none for this release, or gh isn't signed in)"
  fi
fi

ditto -x -k "$TMP/Thermo.zip" "$TMP" || fail "couldn't unzip."
APP="$TMP/Thermo.app"
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "local.thermo" ] || fail "unexpected app inside the zip."
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "the app's signature is broken."
say "✓ App signature intact"

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Thermo 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Thermo.app"
ditto "$APP" "$DEST/Thermo.app"
# Thermo isn't notarized by Apple (that needs a paid developer account), so macOS would block the
# first launch. The checks above did the verifying, so clear the download flag, as Homebrew does.
xattr -dr com.apple.quarantine "$DEST/Thermo.app" 2>/dev/null || true
say "✓ Installed to $DEST/Thermo.app"
open "$DEST/Thermo.app"
say ""
say "🌡️  Thermo is running: look beside your notch or in the menu bar."
say "   Made by Simarpreet Singh · github.com/$REPO"
