#!/bin/sh
# Thermo's own tests: run the built app's command line and MCP server and check what comes back.
# Read-only: nothing is saved or changed. Run after ./build.sh (the quality gate does both).
set -u
cd "$(dirname "$0")/../.."
B=build/Thermo.app/Contents/MacOS/Thermo
[ -x "$B" ] || { echo "✗ build first: ./build.sh"; exit 1; }
FAIL=0
ok() { echo "  ✔ $1"; }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }

"$B" --cli status --json | json 'assert d["cpu"]["percent"]>=0 and d["memory"]["total_gb"]>0 and d["health"]["level"] in ("good","attention","problem")' \
  && ok "status --json has cpu, memory, health" || bad "status --json"
"$B" --cli temps --json | json 'assert "parts" in d and isinstance(d["parts"], list)' \
  && ok "temps --json lists parts" || bad "temps --json"
"$B" --cli battery --json | json 'assert "present" in d' && ok "battery --json" || bad "battery --json"
"$B" --cli apps --limit 3 --json | json 'assert "shared" in d and len(d["processes"])<=3' && ok "apps --limit 3" || bad "apps --json"
"$B" --cli history --json | json 'assert d["range"]=="1h"' && ok "history --json" || bad "history --json"
"$B" --cli headroom --kind gpu --json >/dev/null; c=$?
case $c in 0|3|4) ok "headroom exit code is go/wait/no ($c)";; *) bad "headroom exit code $c";; esac
"$B" --cli nope >/dev/null 2>&1 && bad "unknown command should fail" || ok "unknown command fails"

OUT=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}' | "$B" --mcp)
printf '%s\n' "$OUT" | python3 -c '
import json,sys
m={}
for l in sys.stdin: x=json.loads(l); m[x["id"]]=x
assert set(m)=={1,2,3,4}, "replies"
assert m[1]["result"]["serverInfo"]["name"]=="thermo"
names={t["name"] for t in m[2]["result"]["tools"]}
need={"get_status","get_temperatures","get_top_processes","get_battery","get_history","check_headroom","wait_until_cool","start_benchmark","stop_benchmark","list_benchmarks","compare_benchmarks"}
assert need<=names, need-names
assert all(t["annotations"]["readOnlyHint"] for t in m[2]["result"]["tools"])
assert "cpu" in m[3]["result"]["structuredContent"]
assert m[4]["error"]["code"]==-32602
' && ok "MCP: handshake, 11 read-only tools, tool call, unknown tool error" || bad "MCP server"

V=$(defaults read "$PWD/build/Thermo.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
[ -n "$V" ] && ok "app version $V" || bad "no app version"
[ "$FAIL" = 0 ] && echo "all Thermo tests passed" || echo "$FAIL Thermo test(s) failed"
exit "$FAIL"
