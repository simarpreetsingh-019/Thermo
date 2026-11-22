#!/bin/sh
# After a release is published: build the .mcpb, attach it to the GitHub release, write server.json,
# and publish to the official MCP Registry. Usage: packaging/mcpb/publish.sh 1.10.0
# Needs: gh (logged in), Node, and `mcp-publisher login github` once (brew install mcp-publisher).
set -e
V="${1:?version, e.g. 1.10.0}"; YES="${2:-}"
cd "$(dirname "$0")/../.."
sh packaging/mcpb/build.sh
F="dist/thermo-$V.mcpb"; [ -f "$F" ] || { echo "Built version doesn't match $V (rebuild that tag first)" >&2; exit 1; }
SHA=$(shasum -a 256 "$F" | cut -d' ' -f1)
sed -e "s/VERSION/$V/g" -e "s/SHA256/$SHA/" packaging/mcpb/server.template.json > server.json
if [ "$YES" != --yes ]; then
  printf 'Upload %s to release v%s and publish to the MCP Registry? [y/N] ' "$F" "$V"; read -r ok; [ "$ok" = y ] || exit 1
fi
gh release upload "v$V" "$F" --clobber && echo "✓ $F attached to v$V"
if ! command -v mcp-publisher >/dev/null 2>&1; then
  echo "– MCP Registry skipped: brew install mcp-publisher && mcp-publisher login github, then rerun: packaging/mcpb/publish.sh $V"; exit 0
fi
mcp-publisher publish && echo "✓ MCP Registry → $V" || echo "– MCP Registry publish failed (try: mcp-publisher login github), rerun: packaging/mcpb/publish.sh $V"
