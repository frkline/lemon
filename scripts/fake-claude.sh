#!/bin/bash
# Sandbox stand-in for the `claude` CLI, selected via LEMON_CLAUDE_BIN in
# WorktreeRunner's launcher. Mimics claude's observable surface so the full Lemon
# lifecycle runs with zero tokens — no real model, no session limit.
#
# Behaviour is set by LEMON_FAKE_CLAUDE_MODE (default: complete):
#   complete  announce, then flip the triggering issue's fixture to 🍋 Complete
#             (as real Claude would set the label) so Lemon posts its report + cleans up.
#   question  announce, then idle (simulates a session paused awaiting input).
#   exit      announce, then exit immediately (simulates an early claude exit).
#
# The issue number is read from LEMON_CONTEXT.md in the cwd (the worktree).
# Args mirror claude's; they're logged, not parsed.
set -uo pipefail

MODE="${LEMON_FAKE_CLAUDE_MODE:-complete}"
ISSUES=/tmp/lemon-sandbox/issues

echo "[fake-claude] mode=$MODE launched: $*"

num="$(grep -oE 'sandbox/demo#[0-9]+' LEMON_CONTEXT.md 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
echo "[fake-claude] worktree=$(pwd)  issue=#${num:-unknown}"

set_complete() {
  [ -n "$num" ] || { echo "[fake-claude] no issue number; skipping label flip"; return; }
  python3 - "$ISSUES/$num.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["labelNames"] = ["\U0001F34B Complete"]  # Claude sets 🍋 Complete when the PR is up
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY
  echo "[fake-claude] set 🍋 Complete on sandbox/demo#$num"
}

case "$MODE" in
  complete)
    sleep 5
    set_complete
    # Stay alive briefly so Lemon's 10s label poll observes Complete before exit.
    sleep 30
    ;;
  question)
    echo "[fake-claude] paused — would you like me to proceed? (simulated)"
    sleep 600
    ;;
  exit)
    echo "[fake-claude] exiting immediately"
    ;;
  *)
    echo "[fake-claude] unknown mode '$MODE'"; exit 64 ;;
esac
