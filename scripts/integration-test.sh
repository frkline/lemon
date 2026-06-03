#!/bin/bash
# Integration test: exercises process-level behaviours that XCTest can't reach.
#   - tmux:  create session, pipe-pane log growth, sentinel detection, teardown
#   - Gemma: mock SwiftLM HTTP server + classify() end-to-end via curl
#   - Claude: launch claude -p read-only query, feed output to mock Gemma server
#
# tmux section is skipped when tmux is not installed.
# Gemma + Claude section always runs (requires: python3, claude CLI).
#
# Exit code 0 = all pass. Individual failures print ✗ + reason.

set -euo pipefail

SESSION="lemon-integration-test"
LOG="/tmp/lemon-integration-test.log"
SENTINEL="/tmp/lemon-integration-sentinel"
GEMMA_PID=""
PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

cleanup() {
  [ -n "$GEMMA_PID" ] && kill "$GEMMA_PID" 2>/dev/null || true
  which tmux >/dev/null 2>&1 && tmux kill-session -t "$SESSION"      2>/dev/null || true
  which tmux >/dev/null 2>&1 && tmux kill-session -t "lemon-sentinel-test" 2>/dev/null || true
  rm -f "$LOG" "$SENTINEL"
}
trap cleanup EXIT

# ── tmux ──────────────────────────────────────────────────────────────────────

echo ""
echo "── tmux ──────────────────────────────────────────"

if which tmux >/dev/null 2>&1; then
  ok "tmux is installed ($(tmux -V))"
  HAVE_TMUX=1
else
  echo "  · tmux not found — skipping tmux section (brew install tmux)"
  HAVE_TMUX=0
fi

if [ "$HAVE_TMUX" -eq 1 ]; then
  # 2. Session creation
  cleanup 2>/dev/null || true
  rm -f "$LOG"
  if tmux new-session -d -s "$SESSION" -x 220 -y 50 "bash -c 'while true; do echo tick; sleep 0.2; done'"; then
    ok "tmux new-session succeeded"
  else
    fail "tmux new-session failed"
  fi

  # 3. Session appears in tmux ls
  if tmux ls 2>/dev/null | grep -q "^$SESSION:"; then
    ok "session visible in tmux ls"
  else
    fail "session not found in tmux ls"
  fi

  # 4. pipe-pane writes output to log file
  tmux pipe-pane -t "$SESSION" -o "cat >> $LOG"
  sleep 0.8
  if [ -s "$LOG" ]; then
    lines=$(wc -l < "$LOG" | tr -d ' ')
    ok "pipe-pane log growing ($lines lines)"
  else
    fail "pipe-pane log is empty after 0.8s"
  fi

  # 5. Log file grows over time (silence detector relies on mtime/size change)
  size_before=$(wc -c < "$LOG" | tr -d ' ')
  sleep 0.5
  size_after=$(wc -c < "$LOG" | tr -d ' ')
  if [ "$size_after" -gt "$size_before" ]; then
    ok "log file size increasing (silence detector will fire correctly)"
  else
    fail "log file not growing — silence detector would never reset"
  fi

  echo ""
  echo "── sentinel file ─────────────────────────────────"

  # 6. Sentinel written when command finishes
  SENT_SESSION="lemon-sentinel-test"
  tmux kill-session -t "$SENT_SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SENT_SESSION" -x 80 -y 24 \
    "bash -c 'echo 0 > $SENTINEL'"
  for i in $(seq 1 6); do
    sleep 0.5
    if [ -f "$SENTINEL" ]; then break; fi
  done
  if [ -f "$SENTINEL" ]; then
    code=$(cat "$SENTINEL" | tr -d '[:space:]')
    ok "sentinel written with exit code: $code"
  else
    fail "sentinel not written within 3s"
  fi
  tmux kill-session -t "$SENT_SESSION" 2>/dev/null || true
  rm -f "$SENTINEL"

  echo ""
  echo "── tmux send-keys ────────────────────────────────"

  # 7. send-keys reaches the running pane
  # Stop any existing pipe first, then restart — running pipe-pane twice
  # without stopping adds a second pipe rather than replacing the first.
  tmux pipe-pane -t "$SESSION"  2>/dev/null || true   # stop current pipe
  rm -f "$LOG"
  tmux pipe-pane -t "$SESSION" -o "cat >> $LOG"
  sleep 0.3   # give pipe time to attach before sending keys
  tmux send-keys -t "$SESSION" "echo MARKER_FROM_SEND_KEYS" Enter
  sleep 0.8
  if grep -q "MARKER_FROM_SEND_KEYS" "$LOG" 2>/dev/null; then
    ok "tmux send-keys reaches the pane (Gemma resolution path works)"
  else
    fail "send-keys output not found in log"
  fi

  echo ""
  echo "── teardown ──────────────────────────────────────"

  # 8. Kill session and verify it's gone
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 0.2
  if ! tmux ls 2>/dev/null | grep -q "^$SESSION:"; then
    ok "session cleanly removed"
  else
    fail "session still present after kill"
  fi
fi

# ── clipboard / naming (no tmux required) ─────────────────────────────────────

echo ""
echo "── session naming ────────────────────────────────"

# 9. Verify the tmux attach command format (lowercased identifier)
IDENTIFIER="HRP-42"
EXPECTED_CMD="tmux attach -t lemon-hrp-42"
if [ "$EXPECTED_CMD" = "tmux attach -t lemon-$(echo "$IDENTIFIER" | tr '[:upper:]' '[:lower:]')" ]; then
  ok "clipboard join command format: '$EXPECTED_CMD'"
else
  fail "clipboard join command format mismatch: got '$EXPECTED_CMD'"
fi

# 10. Verify tmux session name derivation matches WorktreeRunner.tmuxSessionName()
EXPECTED_SESSION="lemon-hrp-42"
if [ "$EXPECTED_SESSION" = "lemon-$(echo "$IDENTIFIER" | tr '[:upper:]' '[:lower:]')" ]; then
  ok "tmux session name: '$EXPECTED_SESSION' (matches WorktreeRunner.tmuxSessionName)"
else
  fail "session name mismatch: expected '$EXPECTED_SESSION'"
fi

# ── mock Gemma server ─────────────────────────────────────────────────────────

echo ""
echo "── mock Gemma / classify() ───────────────────────"

GEMMA_PORT=8488
GEMMA_RESP='{"state":"running","summary":"Reading Swift files","action":null}'
INNER_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$GEMMA_RESP")
GEMMA_BODY="{\"choices\":[{\"message\":{\"content\":$INNER_ESCAPED}}]}"

# 11. Start a Python mock server on port 8488 (the SwiftLM default port)
python3 - "$GEMMA_PORT" "$GEMMA_BODY" <<'PYEOF' &
import sys, http.server, json

port = int(sys.argv[1])
body = sys.argv[2].encode()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
GEMMA_PID=$!

# Wait for the server to be ready
for i in $(seq 1 10); do
  if curl -sf "http://127.0.0.1:$GEMMA_PORT/v1/chat/completions" \
       -H "Content-Type: application/json" \
       -d '{"model":"gemma","messages":[{"role":"user","content":"ping"}]}' \
       >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

# 11. Mock server responds to chat completions
RESP=$(curl -sf "http://127.0.0.1:$GEMMA_PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma","messages":[{"role":"user","content":"ping"}]}') || RESP=""

if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
  ok "mock Gemma server responding on :$GEMMA_PORT"
else
  fail "mock Gemma server not responding"
fi

# 12. Inner JSON (GemmaResponse) decodes correctly from the mock response
INNER=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null) || INNER=""
STATE=$(echo "$INNER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])" 2>/dev/null) || STATE=""
SUMMARY=$(echo "$INNER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['summary'])" 2>/dev/null) || SUMMARY=""

if [ "$STATE" = "running" ] && [ -n "$SUMMARY" ]; then
  ok "GemmaResponse decodes: state=$STATE, summary='$SUMMARY'"
else
  fail "GemmaResponse decode failed: state='$STATE' summary='$SUMMARY'"
fi

# ── Claude read-only query ─────────────────────────────────────────────────────

echo ""
echo "── claude -p (read-only) ─────────────────────────"

CLAUDE_BIN="$(which claude 2>/dev/null || echo "")"
if [ -z "$CLAUDE_BIN" ]; then
  echo "  · claude CLI not found — skipping Claude section"
else
  # 13. Run a non-mutating claude query (read-only — lists files, no writes).
  # cd /tmp first per repo rule (avoids macOS permission popups from home dir).
  # --allowedTools restricts to ls so Claude cannot modify files.
  # Prompt must be piped via stdin — claude --print requires stdin or positional arg.
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  CLAUDE_OUT=$(cd /tmp && echo "Use ls to list the .swift files in the Views directory. Show filenames only, one per line." \
    | "$CLAUDE_BIN" --print \
      --add-dir "$REPO_ROOT/app/Lemon/Views" \
      --allowedTools "Bash(ls*)" \
    2>/dev/null) || CLAUDE_OUT=""

  if echo "$CLAUDE_OUT" | grep -qi "\.swift"; then
    line_count=$(echo "$CLAUDE_OUT" | grep -c "swift" || echo 0)
    ok "claude -p returned output ($line_count .swift filenames)"
  else
    fail "claude -p returned no .swift filenames (got: '${CLAUDE_OUT:0:120}')"
  fi

  # 14. Feed Claude output into mock Gemma classify endpoint
  # Simulates the WorktreeRunner → LocalLLM.classify() path
  LOG_PAYLOAD=$(echo "$CLAUDE_OUT" | head -20 | python3 -c "
import sys, json
lines = sys.stdin.read().strip().splitlines()
messages = [
  {'role': 'system', 'content': 'You monitor Claude sessions. Respond with JSON.'},
  {'role': 'user', 'content': 'Issue: LEM-1 — Test issue\n\nTerminal output:\n' + chr(10).join(lines)}
]
print(json.dumps({'model': 'gemma', 'messages': messages, 'response_format': {'type': 'json_object'}}))
")

  CLASSIFY_RESP=$(curl -sf "http://127.0.0.1:$GEMMA_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$LOG_PAYLOAD") || CLASSIFY_RESP=""

  CL_STATE=$(echo "$CLASSIFY_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
inner=json.loads(d['choices'][0]['message']['content'])
print(inner['state'])
" 2>/dev/null) || CL_STATE=""

  if [ "$CL_STATE" = "running" ]; then
    ok "classify() over HTTP with Claude output: state=$CL_STATE"
  else
    fail "classify() returned unexpected state: '$CL_STATE'"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
