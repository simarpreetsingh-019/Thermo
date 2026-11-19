#!/bin/bash
# Publishes a new Thermo version: builds, zips, writes the checksum the in-app updater verifies,
# creates the GitHub release, and bumps the Homebrew tap.
#   ./release.sh 1.4.0 "What's new in this version"
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?usage: ./release.sh <version> [notes]}"; NOTES="${2:-}"
REPO=simarpreetsingh-019/Thermo; TAP_REPO=simarpreetsingh-019/homebrew-thermo

sed -i '' "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$V</string>|" build.sh
./build.sh
rm -f build/Thermo.zip build/Thermo.zip.sha256
(cd build && ditto -c -k --keepParent Thermo.app Thermo.zip && shasum -a 256 Thermo.zip > Thermo.zip.sha256)
SHA=$(cut -d' ' -f1 build/Thermo.zip.sha256)

git add -A && (git commit -qm "Release $V" || true) && git push -q
gh release create "v$V" build/Thermo.zip build/Thermo.zip.sha256 --repo "$REPO" --title "Thermo $V" --notes "$NOTES

**SHA-256:** \`$SHA\`

**Downloading the zip?** macOS will warn that it can't verify Thermo, because it isn't notarized by Apple yet. Here's [how to open it and verify the download yourself](https://github.com/$REPO#first-launch-why-macos-warns-you). No Homebrew? The [installer script](https://github.com/$REPO#install) checks everything for you.

Already have Thermo? It updates itself — look for the orange **Update** button in the panel, or run \`brew upgrade --cask thermo\`.

Made by **Simarpreet Singh** · [simarpreetsingh-019.github.io](https://simarpreetsingh-019.github.io) · [@simarpreet_019](https://x.com/simarpreet_019)
💬 [Send feedback](https://github.com/$REPO/issues/new/choose) · ⭐ Star the repo if Thermo helps you!"

TAP=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP" -- -q
sed -i '' -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/thermo.rb"
# The `thermo` command (shipped inside the app since 1.5.1): let Homebrew put it on the PATH.
grep -q 'binary "#{appdir}/Thermo.app/Contents/Resources/thermo"' "$TAP/Casks/thermo.rb" || \
  sed -i '' 's|^  app "Thermo.app"$|  app "Thermo.app"\
  binary "#{appdir}/Thermo.app/Contents/Resources/thermo", target: "thermo"|' "$TAP/Casks/thermo.rb"
git -C "$TAP" commit -qam "thermo $V" && git -C "$TAP" push -q
rm -rf "$TAP"
echo "Released Thermo $V — https://github.com/$REPO/releases/tag/v$V"
