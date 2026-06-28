#!/bin/bash
# Lemon workflow sandbox harness.
#
# Drives the side-effect-free iteration loop: a file-backed tracker
# (MockIssueClient, enabled by LEMON_SANDBOX=1) over fixtures in /tmp/lemon-sandbox,
# plus a throwaway git "workspace" so WorktreeRunner's `git worktree add ...
# origin/main` works. No GitHub/Linear traffic; no real `claude` tokens (see
# scripts/fake-claude.sh).
#
# See CLAUDE.md → "Workflow sandbox" and memory/sandbox-iteration-loop.md.
set -euo pipefail

ROOT=/tmp/lemon-sandbox
ISSUES="$ROOT/issues"
WORKSPACE="$ROOT/workspace"
ORIGIN="$ROOT/origin.git"

cmd="${1:-help}"; shift || true

init() {
  echo "[sandbox] (re)initializing $ROOT"
  rm -rf "$ROOT"
  mkdir -p "$ISSUES"
  # Bare origin + a clone seeded with main, so `git worktree add ... origin/main`
  # resolves inside the workspace.
  git -c init.defaultBranch=main init --bare -q "$ORIGIN"
  git clone -q "$ORIGIN" "$WORKSPACE"
  ( cd "$WORKSPACE"
    git config user.email sandbox@lemon.local
    git config user.name "Lemon Sandbox"
    printf '# Sandbox workspace\n\nA throwaway repo for Lemon workflow iteration.\n' > README.md
    git add README.md
    git commit -qm "seed sandbox workspace"
    git branch -M main
    git push -q origin main )
  echo "[sandbox] ready. workspace=$WORKSPACE  issues=$ISSUES"
}

issue() {
  local title="${1:-Add a hello function}"
  local body="${2:-Add a hello(name) function and a test.}"
  mkdir -p "$ISSUES"
  local n; n=$(( $(find "$ISSUES" -name '*.json' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
  python3 - "$ISSUES/$n.json" "$n" "$title" "$body" <<'PY'
import json, sys
path, n, title, body = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
json.dump({
    "number": n, "title": title, "description": body,
    "labelNames": ["\U0001F34B"],  # 🍋 trigger
    "comments": [], "commentSeq": 0,
}, open(path, "w"), ensure_ascii=False, indent=2)
PY
  echo "[sandbox] filed sandbox/demo#$n  \"$title\"  (labelled 🍋)"
}

show() {
  for f in "$ISSUES"/*.json; do
    [ -e "$f" ] || { echo "[sandbox] no issues"; return; }
    python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  #{d['number']}  {d['title']}")
print(f"     labels:   {', '.join(d['labelNames']) or '(none)'}")
print(f"     comments: {len(d['comments'])}")
for c in d['comments']:
    print(f"       - [{c['id']}] {c['body'][:70].splitlines()[0] if c['body'] else ''}")
PY
  done
}

reset() { init; }

case "$cmd" in
  init)  init ;;
  issue) issue "${1:-}" "${2:-}" ;;
  show)  show ;;
  reset) reset ;;
  *) cat <<EOF
usage: scripts/sandbox.sh <command>
  init             create fixtures dir + throwaway git workspace (with origin/main)
  issue [t] [body] file a new 🍋-labelled fixture issue (sandbox/demo#N)
  show             print every fixture issue's labels + comments
  reset            wipe and re-init
EOF
  ;;
esac
