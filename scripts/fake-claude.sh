#!/bin/bash
# Sandbox stand-in for the `claude` CLI, selected via LEMON_CLAUDE_BIN in
# WorktreeRunner's launcher. Mimics claude's observable surface so the full Lemon
# lifecycle — including the plan gate — runs with zero tokens.
#
# Plan mode (`--permission-mode plan` in the args): writes a plan to the plan
# sentinel (as the real ExitPlanMode hook would), then blocks on stdin waiting
# for the approval keystroke "1" (which Orchestrator.resolveGate send-keys into
# the pane). After approval it falls through to the build phase.
#
# Build phase behaviour is set by LEMON_FAKE_CLAUDE_MODE (default: complete):
#   complete  flip the triggering issue's fixture to 🍋 Complete (Claude sets the
#             label when the PR is up) so Lemon posts its report + cleans up.
#   question  idle (simulates a session paused awaiting input).
#   exit      exit immediately (simulates an early claude exit).
#
# Issue number + slug are derived from LEMON_CONTEXT.md / the worktree path.
set -uo pipefail

MODE="${LEMON_FAKE_CLAUDE_MODE:-complete}"
ISSUES=/tmp/lemon-sandbox/issues
ARGS="$*"

slug="$(basename "$(pwd)" | sed 's/^lemon-//')"
num="$(grep -oE 'sandbox/demo#[0-9]+' LEMON_CONTEXT.md 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
echo "[fake-claude] launched (mode=$MODE) worktree=$(pwd) issue=#${num:-unknown}"

# --- Plan gate ---------------------------------------------------------------
if [[ "$ARGS" == *"--permission-mode plan"* ]]; then
  echo "[fake-claude] plan mode — drafting plan for sandbox/demo#$num"
  sleep 2
  cat > "/tmp/lemon-plan-$slug.md" <<PLAN
# Plan: sandbox/demo#$num

## Context
A sandbox task. This plan is produced by fake-claude to exercise the plan gate.

## Changes
1. Implement the change described in the issue.
2. Add a test covering it.

## Verification
- Run the test suite; confirm green.
PLAN
  echo "[fake-claude] plan ready — parked at approval picker (send 1 to approve)"
  # Block until Lemon send-keys the approval ("1") into the pane.
  read -r answer || true
  echo "[fake-claude] approval received ('$answer') — entering auto mode, building"
fi

# --- Build phase -------------------------------------------------------------
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
    sleep 4
    set_complete
    sleep 30  # stay alive so Lemon's 10s label poll observes Complete
    ;;
  question)
    echo "[fake-claude] paused — awaiting input (simulated)"
    sleep 600
    ;;
  exit)
    echo "[fake-claude] exiting immediately"
    ;;
  *)
    echo "[fake-claude] unknown mode '$MODE'"; exit 64 ;;
esac
