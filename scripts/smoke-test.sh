#!/bin/bash
# Run the smoke test on the last built binary.
# Called by `make smoke` (after `make build-ui`).
# Screenshots land in /tmp/lemon-smoke/<timestamp>/ with a `latest` symlink.
# Set OPEN_RESULTS=1 to auto-open the directory in Finder when done.
#
# Diffing: uses 32×32 thumbnails via `sips` so time-varying text (countdowns,
# relative timestamps) doesn't mark every file as changed — only structural
# layout differences trigger ★.

set -euo pipefail

APP="/tmp/lemon-build/Lemon.app"
THUMB_DIR="/tmp/lemon-smoke-thumbs"

if [ ! -d "$APP" ]; then
  echo "No build found at $APP — run 'make build-ui' first."
  exit 1
fi

# Snapshot the previous run for diffing
PREV_LATEST=""
if [ -L /tmp/lemon-smoke/latest ]; then
  PREV_LATEST="$(readlink /tmp/lemon-smoke/latest)"
fi

pkill -x Lemon 2>/dev/null || true
sleep 0.3

"$APP/Contents/MacOS/Lemon" --mock --smoke-test &
APP_PID=$!

# Wait for process to self-terminate (SmokeTestDriver calls NSApp.terminate)
TIMEOUT=25
for i in $(seq 1 $TIMEOUT); do
  sleep 1
  if ! kill -0 $APP_PID 2>/dev/null; then
    break
  fi
  if [ $i -eq $TIMEOUT ]; then
    echo "ERROR: timed out after ${TIMEOUT}s"
    kill $APP_PID 2>/dev/null || true
    exit 1
  fi
done

NEW_LATEST=""
if [ -L /tmp/lemon-smoke/latest ]; then
  NEW_LATEST="$(readlink /tmp/lemon-smoke/latest)"
fi

if [ -z "$NEW_LATEST" ]; then
  echo "ERROR: no screenshots found"
  exit 1
fi

# Build 32×32 thumbnails for structural comparison (ignores text rendering noise)
thumb_hash() {
  local src="$1"
  local tmp
  tmp="$(mktemp /tmp/lemon-thumb-XXXXXX.png)"
  sips -Z 32 "$src" --out "$tmp" >/dev/null 2>&1
  md5 -q "$tmp"
  rm -f "$tmp"
}

echo ""
echo "Screenshots → $NEW_LATEST/"
for f in "$NEW_LATEST"/*.png; do
  name="$(basename "$f")"
  if [ -n "$PREV_LATEST" ] && [ -f "$PREV_LATEST/$name" ]; then
    prev_hash="$(thumb_hash "$PREV_LATEST/$name")"
    new_hash="$(thumb_hash "$f")"
    if [ "$prev_hash" != "$new_hash" ]; then
      echo "  ★ $name  (changed)"
    else
      echo "    $name"
    fi
  else
    echo "  + $name  (new)"
  fi
done

if [ "${OPEN_RESULTS:-0}" = "1" ]; then
  open "$NEW_LATEST"
fi
