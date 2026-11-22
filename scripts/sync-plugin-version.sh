#!/bin/sh
# Set the Claude Code plugin + MCPB manifest version to the given release. Usage: scripts/sync-plugin-version.sh 1.10.0
set -e
V="${1:?version}"; cd "$(dirname "$0")/.."
python3 -I - "$V" <<'PY'
import json,sys
v=sys.argv[1]
for f in [".claude-plugin/marketplace.json","plugins/thermo/.claude-plugin/plugin.json","packaging/mcpb/manifest.json"]:
    d=json.load(open(f))
    if "plugins" in d:
        for p in d["plugins"]: p["version"]=v
        d.setdefault("metadata",{})["version"]=v
    else: d["version"]=v
    open(f,"w").write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")
PY
echo "✓ plugin version → $V"
