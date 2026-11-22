#!/bin/bash
# Publish a Thermo release. Runs shipcrate's pipeline (scripts/release.sh: guardrails → quality gate → build →
# checksum → latest.json → GitHub release → Homebrew tap), then Thermo's extras.
#   ./release.sh 1.10.0 --dry-run          preview: builds and prints the notes, publishes nothing
#   ./release.sh 1.10.0                    publish (asks first; add --yes to skip the question)
#   ./release.sh 1.10.0-beta.1             beta testers only ("Get beta updates first"), Homebrew stays put
#   ./release.sh 1.10.0 --rollout 10       staged: 10% first, widen with scripts/rollout.sh 50 / 100
# Notes come from the "## [1.10.0]" section of CHANGELOG.md. See RELEASING.md for rollout, yank and announcements.
set -euo pipefail
cd "$(dirname "$0")"
V=""; DRY=0
for a in "$@"; do case "$a" in --dry-run|-n) DRY=1 ;; -*) ;; *) [ -z "$V" ] && V="${a#v}" ;; esac; done
sh scripts/release.sh "$@"
[ $DRY = 1 ] && exit 0
case "$V" in *-*|"") exit 0 ;; esac   # betas don't move the stable Action tag
# Keep the GitHub Action tag (`uses: simarpreetsingh-019/Thermo@v1`) on the newest stable release.
git fetch -q --tags -f && git tag -f v1 "v$V" >/dev/null && git push -q -f origin v1 && echo "✓ v1 Action tag → v$V"
