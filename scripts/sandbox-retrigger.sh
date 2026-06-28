#!/bin/bash
# Sandbox validation for issue #9 (re-trigger fires on already-shipped revisions
# every launch). Reproduces the exact bug: complete → human reply → RELAUNCH →
# re-trigger → complete → RELAUNCH → must NOT re-trigger again.
#
# With the fix (handleComplete posts a fresh marker-bearing Lemon Report on
# re-trigger completion) the second relaunch sees the advanced marker and stays
# quiet. Asserts the report count + that no spurious re-trigger fires.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=/tmp/lemon-sandbox
ISSUES="$ROOT/issues"
APP=/tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon
MCP=http://127.0.0.1:8765/mcp
ID="sandbox/demo#1"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }
assert(){ if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

APP_PID=""
teardown(){ [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; }
trap teardown EXIT

report_count(){ python3 -c "import json;cs=json.load(open('$ISSUES/1.json'))['comments'];print(sum(1 for c in cs if c['body'].startswith('## \U0001F34B Lemon Report')))" 2>/dev/null||echo 0; }
mcp_status(){ curl -sS -m3 -X POST "$MCP" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}' 2>/dev/null|python3 -c "
import sys,json
try:
 d=json.load(sys.stdin);i=json.loads(d['result']['content'][0]['text'])
 for s in i.get('active',[])+i.get('recent',[]):
  if s.get('identifier')=='$ID':print(s.get('status',''));break
except: pass" 2>/dev/null; }
approve(){ curl -sS -m3 -X POST "$MCP" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve_gate","arguments":{"id":"'"$ID"'","decision":"approve"}}}' >/dev/null 2>&1; }
wait_status(){ for _ in $(seq 1 "$2"); do [ "$(mcp_status)" = "$1" ] && { echo 1;return; }; sleep 1; done; echo 0; }
stop_app(){ pkill -f 'Lemon.app/Contents/MacOS/Lemon' 2>/dev/null||true; for _ in $(seq 1 20); do pgrep -f 'Lemon.app/Contents/MacOS/Lemon'>/dev/null||break; sleep 0.5; done; for _ in $(seq 1 20); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null&&sleep 0.5||break; done; }
start_app(){ LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1 LEMON_CLAUDE_BIN="$(pwd)/scripts/fake-claude.sh" "$APP" >"$ROOT/app.log" 2>&1 & APP_PID=$!; for _ in $(seq 1 30); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null&&break; sleep 1; done; }

echo "── sandbox re-trigger scenario (issue #9) ──────────────────────"
[ -x "$APP" ] || { echo "no built app — run make build-ui"; exit 2; }

# 1. Fresh issue → run the full gated lifecycle to completion (report #1).
stop_app
scripts/sandbox.sh reset >/dev/null
scripts/sandbox.sh issue "Greeting helper" "Add hello(name)." >/dev/null
start_app
echo "[phase] first run → completion"
[ "$(wait_status 'Plan Review' 60)" = 1 ] && approve
[ "$(wait_status 'Result Review' 60)" = 1 ] && approve
[ "$(wait_status 'Reviewing' 60)" = 1 ] || echo "  (warn: never reached Reviewing)"
sleep 2
assert "first completion posted one Lemon Report" "$([ "$(report_count)" = 1 ] && echo 1 || echo 0)" "count=$(report_count)"

# 2. Human replies to the report (a revision request), then app is QUIT.
python3 - "$ISSUES/1.json" <<'PY'
import json,sys,time
p=sys.argv[1]; d=json.load(open(p))
d['commentSeq']=d.get('commentSeq',0)+1
d['comments'].append({"id":f"h{d['commentSeq']}","body":"Please also greet with a time-of-day prefix.","createdAt":time.time()})
json.dump(d,open(p,'w'),ensure_ascii=False,indent=2)
print("added human reply")
PY
stop_app
# Simulate the user clicking "Cleanup worktree" (the real flow tears down the
# .reviewing worktree before the next launch). Without this the leftover
# worktree blocks the re-trigger's `git worktree add`.
rm -rf /tmp/lemon-sandbox-demo-1 2>/dev/null
tmux kill-session -t lemon-sandbox-demo-1 2>/dev/null || true

# 3. RELAUNCH → the reply legitimately re-triggers; let it complete (report #2).
echo "[phase] relaunch #1 → expect ONE re-trigger"
start_app
retrig1="$(wait_status 'Executing' 75)"   # re-trigger goes straight to auto/build
[ "$retrig1" = 1 ] || retrig1="$([ "$(mcp_status)" = "Planning" ] && echo 1 || echo 0)"
reached2="$(wait_status 'Reviewing' 75)"
sleep 2
assert "reply re-triggered exactly once"        "$retrig1"
assert "re-trigger posted a 2nd Lemon Report (marker advanced)" "$([ "$(report_count)" = 2 ] && echo 1 || echo 0)" "count=$(report_count)"
stop_app

# 4. RELAUNCH again → with the marker advanced, must NOT re-trigger.
echo "[phase] relaunch #2 → expect NO re-trigger (the #9 fix)"
start_app
sleep 30   # give it well past a poll cycle to (not) pick anything up
status_now="$(mcp_status)"
count_now="$(report_count)"
# No spurious re-trigger: the issue is not being worked again and no 3rd report.
assert "no spurious re-trigger after marker advance" "$([ "$status_now" != 'Executing' ] && [ "$status_now" != 'Planning' ] && [ "$count_now" = 2 ] && echo 1 || echo 0)" "status=$status_now reports=$count_now"

echo "────────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "  SCENARIO PASSED" || echo "  SCENARIO FAILED"
exit "$FAIL"
