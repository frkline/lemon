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

clean_artifacts() {
  # Worktrees/tmux/sentinels/launchers live at /tmp siblings, not under $ROOT,
  # so wipe them explicitly or a stale worktree fails the next `git worktree add`.
  tmux ls 2>/dev/null | grep -oE '^lemon-sandbox-demo-[^:]+' \
    | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
  rm -rf /tmp/lemon-sandbox-demo-* 2>/dev/null || true
  rm -f /tmp/lemon-exit-sandbox-demo-* /tmp/lemon-launch-sandbox-demo-*.sh \
        /tmp/lemon-mcp-sandbox-demo-* 2>/dev/null || true
}

init() {
  echo "[sandbox] (re)initializing $ROOT"
  clean_artifacts
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
  local author="${3:-sandbox}"        # issue opener; default = the sandbox user
  local labeledBy="${4:-$author}"     # who applied 🍋; default = the author
  mkdir -p "$ISSUES"
  local n; n=$(( $(find "$ISSUES" -name '*.json' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
  python3 - "$ISSUES/$n.json" "$n" "$title" "$body" "$author" "$labeledBy" <<'PY'
import json, sys
path, n, title, body, author, labeledBy = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
json.dump({
    "number": n, "title": title, "description": body,
    "labelNames": ["\U0001F34B"],  # 🍋 trigger
    "comments": [], "commentSeq": 0, "author": author, "labeledBy": labeledBy,
}, open(path, "w"), ensure_ascii=False, indent=2)
PY
  echo "[sandbox] filed sandbox/demo#$n  \"$title\"  by @$author  labelled-by @$labeledBy"
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
  issue) issue "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
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
