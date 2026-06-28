#!/bin/bash
# Sandbox validation for the request-changes loop: plan → request changes →
# revised plan (new Lemon Plan comment) → approve → build → result gate → PR.
# Asserts the re-plan cycle works and Lemon stays resilient across a revision.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=/tmp/lemon-sandbox; ISSUES="$ROOT/issues"
APP=/tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon
MCP=http://127.0.0.1:8765/mcp; ID="sandbox/demo#1"
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }; bad(){ echo "  ✗ $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }
assert(){ if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
APP_PID=""; teardown(){ [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; }; trap teardown EXIT

plan_count(){ python3 -c "import json;cs=json.load(open('$ISSUES/1.json'))['comments'];print(sum(1 for c in cs if c['body'].startswith('## \U0001F34B Lemon Plan')))" 2>/dev/null||echo 0; }
mcp_status(){ curl -sS -m3 -X POST "$MCP" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}' 2>/dev/null|python3 -c "
import sys,json
try:
 d=json.load(sys.stdin);i=json.loads(d['result']['content'][0]['text'])
 for s in i.get('active',[])+i.get('recent',[]):
  if s.get('identifier')=='$ID':print(s.get('status',''));break
except: pass" 2>/dev/null; }
gate(){ curl -sS -m3 -X POST "$MCP" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve_gate","arguments":{"id":"'"$ID"'","decision":"'"$1"'"}}}' >/dev/null 2>&1; }
wait_status(){ for _ in $(seq 1 "$2"); do [ "$(mcp_status)" = "$1" ] && { echo 1;return; }; sleep 1; done; echo 0; }
wait_planN(){ for _ in $(seq 1 "$2"); do [ "$(plan_count)" -ge "$1" ] && { echo 1;return; }; sleep 1; done; echo 0; }

echo "── sandbox request-changes scenario ────────────────────────────"
[ -x "$APP" ] || { echo "no built app — run make build-ui"; exit 2; }
pkill -f "$APP" 2>/dev/null||true
for _ in $(seq 1 20); do pgrep -f "$APP">/dev/null||break; sleep 0.5; done
for _ in $(seq 1 20); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null&&sleep 0.5||break; done
scripts/sandbox.sh reset >/dev/null
scripts/sandbox.sh issue "Greeting helper" "Add hello(name)." >/dev/null
LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1 LEMON_CLAUDE_BIN="$(pwd)/scripts/fake-claude.sh" "$APP" >"$ROOT/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null&&break; sleep 1; done

echo "[phase] plan v1"
assert "reached Plan Review (v1)" "$(wait_status 'Plan Review' 60)"
assert "one plan posted" "$([ "$(plan_count)" = 1 ] && echo 1 || echo 0)" "count=$(plan_count)"

echo "[phase] request changes → expect a revised plan"
gate request_changes
assert "revised plan posted (2nd Lemon Plan)" "$(wait_planN 2 60)" "count=$(plan_count)"
assert "still parked at Plan Review after revision" "$(wait_status 'Plan Review' 30)" "status=$(mcp_status)"

echo "[phase] approve revised plan → build → result gate → PR"
gate approve
assert "reached Result Review after approval" "$(wait_status 'Result Review' 75)" "status=$(mcp_status)"
gate approve
assert "reached Reviewing (completed)" "$(wait_status 'Reviewing' 75)" "status=$(mcp_status)"

echo "────────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "  SCENARIO PASSED" || echo "  SCENARIO FAILED"
exit "$FAIL"
