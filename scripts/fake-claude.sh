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

PLAN_MODE=0

# --- Plan gate ---------------------------------------------------------------
# Loop on the approval picker: "1" approves; anything else (e.g. "4", the
# "tell Claude what to change" option Lemon send-keys for request-changes) means
# revise — write a fresh plan and wait again. This exercises the re-plan loop.
if [[ "$ARGS" == *"--permission-mode plan"* ]]; then
  PLAN_MODE=1
  attempt=1
  while true; do
    sleep 2
    if [ "$attempt" = 1 ]; then
      cat > "/tmp/lemon-plan-$slug.md" <<PLAN
# Plan: sandbox/demo#$num

## Context
A sandbox task. fake-claude produced this to exercise the plan gate.

## Changes
1. Implement the change described in the issue.
2. Add a test covering it.
PLAN
    else
      cat > "/tmp/lemon-plan-$slug.md" <<PLAN
# Plan (revision $attempt): sandbox/demo#$num

## Context
Revised per the requested changes.

## Changes
1. Implement the change, addressing the reviewer feedback.
2. Add a test covering it AND the edge case raised in review.
PLAN
    fi
    echo "[fake-claude] plan v$attempt ready — parked at approval picker (1=approve, else=revise)"
    read -r answer || true
    if [ "$answer" = "1" ]; then
      echo "[fake-claude] approved — entering auto mode, building"
      break
    fi
    echo "[fake-claude] changes requested ('$answer') — re-planning (v$((attempt + 1)))"
    attempt=$((attempt + 1))
  done
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
    # Result gate: a plan-gated session signals "ready for review" instead of
    # opening the PR directly, and waits for the human's go.
    if [ "$PLAN_MODE" = 1 ]; then
      echo "[fake-claude] build done — signalling ready for review"
      cat > "/tmp/lemon-result-$slug.md" <<RESULT
Built sandbox/demo#$num — 2 files changed, tests green. Awaiting approval to open the PR.
RESULT
      echo "[fake-claude] parked at result gate (awaiting approval to open PR)"
      read -r approve2 || true
      echo "[fake-claude] result approved ('$approve2') — opening PR"
    fi
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
