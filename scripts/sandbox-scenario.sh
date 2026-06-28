#!/bin/bash
# Asserting scenario runner for the Lemon workflow sandbox.
#
# Drives one issue through the FULL plan-gate lifecycle (file-backed tracker +
# fake-claude) and asserts each transition, with a PASS/FAIL summary and a real
# exit code — so the workflow is regression-tested with no GitHub/Linear traffic
# or claude tokens. Wraps scripts/sandbox.sh; expects a built app at /tmp/lemon-build.
#
#   plan gate:   🍋 → planning → Plan posted → Plan Review  ──approve──┐
#   build:       Executing → 🍋 Complete → Lemon Report → Reviewing  ◄─┘
#
# See CLAUDE.md → "Workflow sandbox" and memory/sandbox-iteration-loop.md.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=/tmp/lemon-sandbox
ISSUES="$ROOT/issues"
APP=/tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon
MCP=http://127.0.0.1:8765/mcp
ID="sandbox/demo#1"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }
assert() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

APP_PID=""
SLUG="sandbox-demo-1"           # pathSlug of sandbox/demo#1 → tmux lemon-$SLUG
teardown() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; }
trap teardown EXIT

# --- app lifecycle (shared by the initial launch + the reattach relaunch) ----
launch_app() {
  LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1 LEMON_CLAUDE_BIN="$(pwd)/scripts/fake-claude.sh" \
    "$APP" >>"$ROOT/app.log" 2>&1 &
  APP_PID=$!
  echo "[setup] launched sandbox Lemon (pid $APP_PID); waiting for MCP…"
  for _ in $(seq 1 30); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null && break; sleep 1; done
}
stop_app() { # SIGTERM the app ONLY — the detached tmux session must survive
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null && sleep 0.5 || break; done
  for _ in $(seq 1 20); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null && sleep 0.5 || break; done
  APP_PID=""
}
tmux_alive() { tmux -L lemon has-session -t "lemon-$SLUG" 2>/dev/null && echo 1 || echo 0; }

# --- probes -----------------------------------------------------------------
fixture_has_comment() { # $1=num  $2=python-prefix-expr -> 1/0
  python3 -c "import json;cs=json.load(open('$ISSUES/$1.json'))['comments'];print(1 if any(c['body'].startswith($2) for c in cs) else 0)" 2>/dev/null || echo 0
}
has_plan()   { fixture_has_comment 1 "'## \U0001F34B Lemon Plan'"; }
has_report() { fixture_has_comment 1 "'## \U0001F34B Lemon Report'"; }
mcp_status() {
  curl -sS -m 3 -X POST "$MCP" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}' 2>/dev/null \
  | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); inner=json.loads(d['result']['content'][0]['text'])
    for s in inner.get('active',[])+inner.get('recent',[]):
        if s.get('identifier')=='$ID': print(s.get('status','')); break
except Exception: pass" 2>/dev/null
}
mcp_has_worktree() {
  curl -sS -m 3 -X POST "$MCP" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}' 2>/dev/null \
  | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); inner=json.loads(d['result']['content'][0]['text'])
    for s in inner.get('active',[])+inner.get('recent',[]):
        if s.get('identifier')=='$ID' and s.get('worktree_path'): print(1); break
    else: print(0)
except Exception: print(0)" 2>/dev/null
}
approve_gate() {
  curl -sS -m 3 -X POST "$MCP" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve_gate","arguments":{"id":"'"$ID"'","decision":"approve"}}}' 2>/dev/null
}
wait_for_status() { # $1=target  $2=timeout-secs -> 1/0
  for _ in $(seq 1 "$2"); do
    [ "$(mcp_status)" = "$1" ] && { echo 1; return; }
    sleep 1
  done
  echo 0
}

echo "── sandbox plan-gate scenario ──────────────────────────────────"
[ -x "$APP" ] || { echo "[setup] no built app at $APP — run 'make build-ui' first"; exit 2; }

# 1. Stop any running Lemon; wait for process gone + MCP port free.
echo "[setup] stopping any running Lemon"
pkill -f "$APP" 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -f "$APP" >/dev/null || break; sleep 0.5; done
for _ in $(seq 1 20); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null && sleep 0.5 || break; done

# 2. Clean slate (also wipes stale worktrees) + seed one issue.
echo "[setup] resetting sandbox + filing $ID"
scripts/sandbox.sh reset >/dev/null
scripts/sandbox.sh issue "Add a hello function" "Add hello(name) and a test." >/dev/null

# 3. Launch in sandbox mode; wait for MCP up.
: >"$ROOT/app.log"
launch_app

# 4. PLAN GATE — wait for the session to reach Plan Review.
echo "[phase] waiting for plan gate…"
reached_plan_review="$(wait_for_status 'Plan Review' 60)"
saw_worktree="$(mcp_has_worktree)"
plan_posted="$(has_plan)"

echo "── plan gate assertions ────────────────────────────────────────"
assert "session created (worktree via MCP)"     "$saw_worktree"
assert "plan posted to issue (Lemon Plan)"       "$plan_posted"
assert "reached Plan Review gate"                "$reached_plan_review" "status=$(mcp_status)"

# 4b. REATTACH (issue #35) — at Plan Review the detached tmux session is alive
# (fake-claude is blocked on the approval read). SIGTERM the app ONLY, relaunch,
# and assert the session is re-adopted at the same status (not ABSENT) — proving
# restoreSessions reattached a live session rather than orphaning or killing it.
echo "[phase] reattach: killing app (tmux survives), relaunching…"
tmux_before="$(tmux_alive)"
stop_app
tmux_survived="$(tmux_alive)"
absent_while_down="$([ -z "$(mcp_status)" ] && echo 1 || echo 0)"  # MCP down → no status
launch_app
reattached_plan_review="$(wait_for_status 'Plan Review' 60)"
reattached_worktree="$(mcp_has_worktree)"

echo "── reattach assertions (issue #35) ─────────────────────────────"
assert "tmux session alive at Plan Review"       "$tmux_before"
assert "tmux session survived app SIGTERM"       "$tmux_survived"
assert "MCP gone while app down"                 "$absent_while_down"
assert "session reattached at Plan Review"       "$reattached_plan_review" "status=$(mcp_status)"
assert "reattached session has its worktree"     "$reattached_worktree"

# 5. APPROVE the plan via the MCP gate tool (what the popover button calls).
echo "[phase] approving plan via approve_gate…"
plan_approve_out="$(approve_gate)"

# 6. RESULT GATE — build runs, then parks at Result Review; approve to open PR.
echo "[phase] waiting for result gate…"
reached_result_review="$(wait_for_status 'Result Review' 60)"

echo "── result gate assertions ──────────────────────────────────────"
assert "plan approved → resolved"                "$([ "$(echo "$plan_approve_out" | grep -c resolved)" -ge 1 ] && echo 1 || echo 0)"
assert "reached Result Review gate"              "$reached_result_review" "status=$(mcp_status)"

echo "[phase] approving result via approve_gate…"
result_approve_out="$(approve_gate)"

# 7. BUILD COMPLETION — PR opens, report posted, Reviewing.
echo "[phase] waiting for completion…"
reached_reviewing="$(wait_for_status 'Reviewing' 60)"
sleep 2
report_posted="$(has_report)"

echo "── completion assertions ───────────────────────────────────────"
assert "result approved → resolved"              "$([ "$(echo "$result_approve_out" | grep -c resolved)" -ge 1 ] && echo 1 || echo 0)"
assert "Lemon Report comment posted"             "$report_posted"
assert "reached Reviewing (post-build)"          "$reached_reviewing" "status=$(mcp_status)"

echo "────────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "  SCENARIO PASSED" || echo "  SCENARIO FAILED"
exit "$FAIL"
