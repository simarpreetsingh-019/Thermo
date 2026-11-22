#!/bin/sh
# Builds dist/thermo-<version>.mcpb: Thermo's MCP server as a one-click Claude Desktop extension.
# Run after ./build.sh. Needs Node (npx @anthropic-ai/mcpb).
set -e
cd "$(dirname "$0")/../.."
BIN=build/Thermo.app/Contents/MacOS/Thermo
[ -x "$BIN" ] || { echo "Run ./build.sh first" >&2; exit 1; }
VER=$("$BIN" --version | awk '{print $NF}')
STAGE=build/mcpb; rm -rf "$STAGE"; mkdir -p "$STAGE/server" dist
sed "s/\"version\": \"[^\"]*\"/\"version\": \"$VER\"/" packaging/mcpb/manifest.json > "$STAGE/manifest.json"
cp "$BIN" "$STAGE/server/Thermo"; cp docs/icon.png "$STAGE/icon.png"
npx -y @anthropic-ai/mcpb@2.1.2 validate "$STAGE/manifest.json"
npx -y @anthropic-ai/mcpb@2.1.2 pack "$STAGE" "dist/thermo-$VER.mcpb"
shasum -a 256 "dist/thermo-$VER.mcpb"
