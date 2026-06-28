#!/bin/bash
# Asserting scenario runner for the Lemon workflow sandbox.
#
# Drives a full issue through the file-backed loop (MockIssueClient + fake-claude)
# and ASSERTS each expected transition, with a PASS/FAIL summary and a real exit
# code — so the workflow can be regression-tested without GitHub/Linear traffic or
# claude tokens. Wraps scripts/sandbox.sh; expects a built app at /tmp/lemon-build.
#
# Usage: scripts/sandbox-scenario.sh [scenario]
#   happy-path (default)  🍋 → In Progress → Complete → Lemon Report → Reviewing
#
# See CLAUDE.md → "Workflow sandbox" and memory/sandbox-iteration-loop.md.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=/tmp/lemon-sandbox
ISSUES="$ROOT/issues"
APP=/tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon
MCP=http://127.0.0.1:8765/mcp
SCENARIO="${1:-happy-path}"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
assert() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1"; fi; }

APP_PID=""
teardown() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; }
trap teardown EXIT

# --- fixture / MCP probes ---------------------------------------------------
fixture_labels() { # $1 = issue number
  python3 -c "import json;print(','.join(json.load(open('$ISSUES/$1.json'))['labelNames']))" 2>/dev/null
}
fixture_has_report() { # $1 = issue number  -> echoes 1/0
  python3 -c "import json;cs=json.load(open('$ISSUES/$1.json'))['comments'];print(1 if any(c['body'].startswith('## \U0001F34B Lemon Report') for c in cs) else 0)" 2>/dev/null || echo 0
}
mcp_field() { # $1 = issue identifier, $2 = field -> echoes value or ""
  curl -sS -m 3 -X POST "$MCP" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}' 2>/dev/null \
  | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); inner=json.loads(d['result']['content'][0]['text'])
    for s in inner.get('active',[])+inner.get('recent',[]):
        if s.get('identifier')=='$1': print(s.get('$2','')); break
except Exception: pass" 2>/dev/null
}

echo "── sandbox scenario: $SCENARIO ─────────────────────────────────"

[ -x "$APP" ] || { echo "[setup] no built app at $APP — run 'make build-ui' first"; exit 2; }

# 1. Kill ANY existing Lemon and wait until the process is gone AND the MCP port
#    is free — otherwise a leftover instance answers MCP and we assert the wrong
#    process's state (the bug this runner caught on day one).
echo "[setup] stopping any running Lemon"
pkill -f 'Lemon.app/Contents/MacOS/Lemon' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -f 'Lemon.app/Contents/MacOS/Lemon' >/dev/null || break; sleep 0.5; done
for _ in $(seq 1 20); do curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null && sleep 0.5 || break; done

# 2. Clean slate (also wipes stale worktrees) + seed one issue BEFORE launch so
#    the first poll picks it up fast.
echo "[setup] resetting sandbox + filing sandbox/demo#1"
scripts/sandbox.sh reset >/dev/null
scripts/sandbox.sh issue "Add a hello function" "Add hello(name) and a test." >/dev/null

# 3. Launch the app in sandbox mode (fake-claude, MCP on) and wait for MCP up.
LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1 LEMON_CLAUDE_BIN="$(pwd)/scripts/fake-claude.sh" \
  "$APP" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
echo "[setup] launched sandbox Lemon (pid $APP_PID); waiting for MCP…"
mcp_up=0
for _ in $(seq 1 30); do
  curl -sS -m1 "$MCP" -o /dev/null 2>/dev/null && { mcp_up=1; break; }
  sleep 1
done
[ "$mcp_up" = 1 ] && echo "[setup] MCP up" || echo "[setup] WARNING: MCP never responded"

# 3. Poll fast, recording the label sequence + observing the session, until
#    Complete or timeout.
seq=""; saw_inprogress=0; saw_worktree=0; reached_complete=0
for i in $(seq 1 90); do
  labels="$(fixture_labels 1)"
  case "$labels" in
    *"In Progress"*) saw_inprogress=1 ;;
  esac
  [ -n "$(mcp_field 'sandbox/demo#1' worktree_path)" ] && saw_worktree=1
  # record distinct label transitions
  [ "$labels" != "${seq##*$'\n'}" ] && seq="$seq$labels"$'\n'
  case "$labels" in
    *"Complete"*) reached_complete=1; break ;;
  esac
  sleep 1
done

# Lemon detects the Complete label on its OWN ~10s poll, then posts the report
# and moves to Reviewing — wait for that, don't sample once.
status=""; has_report=0
for _ in $(seq 1 25); do
  status="$(mcp_field 'sandbox/demo#1' status)"
  has_report="$(fixture_has_report 1)"
  [ "$has_report" = 1 ] && [ "$status" = "Reviewing" ] && break
  sleep 1
done

echo "[observed] label transitions:"
printf '%s' "$seq" | sed 's/^/             /'
echo "[observed] mcp status: ${status:-<none>}"

# 4. Assertions.
echo "── assertions ──────────────────────────────────────────────────"
assert "session created (worktree via MCP)"        "$saw_worktree"
assert "passed through 🍋 In Progress"             "$saw_inprogress"
assert "reached 🍋 Complete"                        "$reached_complete"
assert "Lemon Report comment posted"                "$has_report"
assert "MCP session status == Reviewing"            "$([ "$status" = "Reviewing" ] && echo 1 || echo 0)"

echo "────────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "  SCENARIO PASSED" || echo "  SCENARIO FAILED"
exit "$FAIL"
