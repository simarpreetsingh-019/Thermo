#!/bin/bash
# Publishes a new Thermo version: builds, zips, writes the checksum the in-app updater verifies,
# creates the GitHub release, and bumps the Homebrew tap.
#   ./release.sh 1.4.0 "What's new in this version"
#   ./release.sh 1.10.0-beta.1 "…"   beta: only people with "Get beta updates first" on (maintainers/testers) get it;
#                                     no Homebrew bump, not "latest" on GitHub, so everyone else never sees it.
# Also publishes latest.json (+ .sig with signed updates) for the in-app updater (shipcrate, Sources/Updater.swift),
# and keeps Thermo.zip + Thermo.zip.sha256 so copies on 1.9.0 and older (old updater) still update.
# Afterwards: scripts/rollout.sh, scripts/yank.sh, scripts/announce.sh, scripts/stats.sh (see release.conf).
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?usage: ./release.sh <version> [notes]}"; NOTES="${2:-}"
PRE=0; case "$V" in *-*) PRE=1 ;; esac
REPO=simarpreetsingh-019/Thermo; TAP_REPO=simarpreetsingh-019/homebrew-thermo

sed -i '' "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$V</string>|" build.sh
./build.sh
rm -f build/Thermo.zip build/Thermo.zip.sha256
(cd build && ditto -c -k --keepParent Thermo.app Thermo.zip && shasum -a 256 Thermo.zip > Thermo.zip.sha256)
SHA=$(cut -d' ' -f1 build/Thermo.zip.sha256)

BODY="$NOTES

**SHA-256:** \`$SHA\`

**Downloading the zip?** macOS will warn that it can't verify Thermo, because it isn't notarized by Apple yet. Here's [how to open it and verify the download yourself](https://github.com/$REPO#first-launch-why-macos-warns-you). No Homebrew? The [installer script](https://github.com/$REPO#install) checks everything for you.

Already have Thermo? It updates itself — look for the orange **Update** button in the panel, or run \`brew upgrade --cask thermo\`.

Made by **Simarpreet Singh** · [simarpreetsingh-019.github.io](https://simarpreetsingh-019.github.io) · [@simarpreet_019](https://x.com/simarpreet_019)
💬 [Send feedback](https://github.com/$REPO/issues/new/choose) · ⭐ Star the repo if Thermo helps you!"
[ $PRE = 1 ] && BODY="> 🧪 **Beta** for testers: only copies with \"Get beta updates first\" turned on are offered this.

$BODY"

# Update manifest for the in-app updater (shipcrate): latest.json (+ latest.json.sig when signed updates are on).
rm -rf dist && mkdir -p dist && cp build/Thermo.zip build/Thermo.zip.sha256 dist/
printf '%s\n' "$BODY" > dist/notes.md
sh scripts/manifest.sh "$V"
ASSETS=(dist/Thermo.zip dist/Thermo.zip.sha256 dist/latest.json dist/SHA256SUMS)
[ -f dist/latest.json.sig ] && ASSETS+=(dist/latest.json.sig)

git add -A && (git commit -qm "Release $V" || true) && git push -q
PREFLAG=(); [ $PRE = 1 ] && PREFLAG=(--prerelease)
gh release create "v$V" "${ASSETS[@]}" ${PREFLAG[@]+"${PREFLAG[@]}"} --repo "$REPO" --title "Thermo $V" --notes-file dist/notes.md
sh scripts/channel.sh dist/latest.json   # beta testers get every release (beta and stable) through beta.json
if [ $PRE = 1 ]; then
  echo "Released beta Thermo $V for testers only — https://github.com/$REPO/releases/tag/v$V"
  exit 0
fi

TAP=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP" -- -q
sed -i '' -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/thermo.rb"
# The `thermo` command (shipped inside the app since 1.5.1): let Homebrew put it on the PATH.
grep -q 'binary "#{appdir}/Thermo.app/Contents/Resources/thermo"' "$TAP/Casks/thermo.rb" || \
  sed -i '' 's|^  app "Thermo.app"$|  app "Thermo.app"\
  binary "#{appdir}/Thermo.app/Contents/Resources/thermo", target: "thermo"|' "$TAP/Casks/thermo.rb"
git -C "$TAP" commit -qam "thermo $V" && git -C "$TAP" push -q
rm -rf "$TAP"
# Keep the GitHub Action tag (`uses: …/Thermo@v1`) on the newest release.
git fetch -q --tags -f && git tag -f v1 "v$V" >/dev/null && git push -q -f origin v1
echo "Released Thermo $V — https://github.com/$REPO/releases/tag/v$V"
