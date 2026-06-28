# Dogfooding Lemon — tag & monitor handoff

A playbook for a **fresh Claude Code session** driving Lemon's own issues through
Lemon itself: label an issue 🍋, Lemon spins a worktree + launches `claude`, and you
**monitor and shepherd** it through the plan gate to a PR — while watching for (and
fixing) any Lemon bug the run surfaces. Read this first, then `CLAUDE.md` + `memory/`.

> You are the **operator/observer**, not the implementer. Lemon's spawned `claude`
> does the issue's work; you trigger it, watch via MCP/tmux, approve the gate, surface
> the PR, and capture/fix anything that breaks. Keep the conclusions, not the file dumps.

## 0. Pre-flight (every session — do not skip)

1. **Confirm the hardened build is live.** `main` must include PR #47 (isolation #40 +
   classify-input bounding #44 + session-limit recovery #39) and #38 (reattach). Check:
   `git -C /Users/frank/Projects/lemon log --oneline -3 origin/main` → expect the
   "#47 Robustness…" merge. Then **rebuild Lemon from main and relaunch** — the running
   binary must include #47.
2. **Single, clean Lemon instance.** `pgrep -fl 'Lemon.app/Contents/MacOS/Lemon'` →
   exactly one. Kill strays. MCP up: `curl -sS -m3 -X POST http://127.0.0.1:8765/mcp
   -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
   "params":{"name":"list_sessions","arguments":{}}}'`
3. **No env contamination** (post-#40 Lemon uses a dedicated `-L lemon` socket, but
   verify): `tmux -L lemon ls 2>/dev/null` and `tmux show-environment -g 2>/dev/null |
   grep LEMON_`. If a stale server holds `LEMON_SANDBOX`/`LEMON_CLAUDE_BIN` →
   `tmux kill-server` (and `tmux -L lemon kill-server`).
4. **Gemma/SwiftLM healthy.** `pgrep -fl SwiftLM`; `tail -3 /tmp/lemon-swiftlm.log`
   should end at "Ready / Listening on …:8488". (If you killed it, relaunch Lemon to
   respawn it.)
5. **Menu-bar glyph is idle, not error.** Known bug #48: a past `.failed` recent session
   pins the glyph to error even when idle. If stuck red after a clean relaunch with no
   leftover `/tmp/lemon-*` worktrees, it's cosmetic — note it, don't chase it.

## 1. Trigger an issue (GitHub lockdown is ON)

Lemon's trigger requires **both**: assignee = you **and** the 🍋 labeler = you. So:

```sh
gh issue edit <N> --repo frkline/lemon --add-assignee frkline --add-label "🍋 Lemon"
```

- The trigger label is literally **`🍋 Lemon`** (not bare `🍋`).
- **Unassigned issues won't trigger** — always `--add-assignee frkline`.
- Lemon polls ~45s idle / ~15s active.

## 2. Monitor (from your session)

- **MCP tools** (`http://127.0.0.1:8765/mcp`, `tools/call`): read — `list_sessions`,
  `get_session`, `get_pane_log`, `force_classify`, `get_swiftlm_log`; write —
  `approve_gate` (`decision=approve|request_changes`), `send_keys`, `stop_session`.
- **Read the pane cleanly with tmux, not raw get_pane_log:**
  `tmux -L lemon capture-pane -t lemon-<slug> -p | grep -v '^[[:space:]]*$' | tail -20`.
  Slug for GitHub = `owner-repo-N` (e.g. `frkline-lemon-41`).
- **Milestones to watch:** `🍋 In Progress` (picked up) → plan written
  (`/tmp/lemon-plan-<slug>.md`) → **Plan Review** gate (Lemon posts "🍋 Lemon Plan",
  parks at `.waiting`) → approve → build (auto mode) → PR opened → `🍋 Complete`.
- Background-poll with a `Bash run_in_background` loop that exits on a milestone; don't
  busy-wait in the foreground.

## 3. The gates

- **Plan Review:** surface the plan to the user first. Approve via the app's popover
  button, or `approve_gate` MCP, or `send_keys "1"`. **Request changes** =
  `approve_gate decision=request_changes` (or `send_keys "4"` + feedback).
- **Mid-plan scope/permission pickers:** claude may park on its own picker (scope
  question) or a Bash permission prompt (`find -exec`, `cd`+redirect — benign,
  read-only). Surface scope questions to the user; clear obviously-safe read-only
  prompts with `send_keys "1"` (or Enter on the highlighted option).
- **Inject extra scope** like we did mid-plan: `send_keys` the text (payload via a JSON
  file to avoid shell-escaping), **then a SEPARATE `Enter`** (see gotcha below).

## 4. Known failure modes & how to handle (hard-won this session)

- **`send_keys` doesn't submit text.** `append_enter:true` leaves a typed message queued
  in claude's composer. Always send the text, **then a separate `Enter` keystroke**.
- **Session limit (Max).** Post-#39 Lemon auto-parks (`🍋 Waiting`, "⏳ Max limit —
  resuming HH:MM") and auto-resumes at the reset. If you must nudge manually: text + a
  separate Enter.
- **CPU runaway (pre-#44).** Fixed: classify input is now ANSI-stripped + char-capped.
  If SwiftLM ever pins CPU again, check `/tmp/lemon-swiftlm.log` for
  `prompt=<huge>t | prefilling` — that's an input-bounding regression.
- **Tracking desync.** If Lemon shows a stuck status while `claude` keeps building,
  you're in **manual-shepherd mode** — watch the worktree and surface the PR yourself.
- **Salvage pattern** (Lemon lost the thread but `claude` did the work): the impl is
  uncommitted in `/tmp/lemon-<slug>`. Verify with **plain tooling only** —
  `xcodebuild … test`, `swiftformat`, `swiftlint --strict` — then commit explicit paths
  (exclude `.claude/`, `LEMON_CONTEXT.md`, `.lemon-summary.md`), push, open the PR.
- **NEVER, from inside a Lemon session, run** `make sandbox*`, `scripts/sandbox*.sh`,
  `tmux kill-server`, or `pkill -f Lemon` — they kill the session you're in. (Post-#40
  the worktree's `LEMON_CONTEXT` warns the agent; don't do it yourself when salvaging.)

## 5. Always before pushing

CI runs a **separate `lint` job** — a clean build/test is **not** enough. Run
`swiftformat app/Lemon app/LemonTests` then `swiftlint lint --strict` (0 violations)
before every push. See `memory/ci-lint-swiftformat.md`.

## 6. Candidate issues (#41–#46)

| # | State | Title | Notes |
|---|-------|-------|-------|
| **#41** | open · assigned | "Open PR" affordance in the session row/detail | **Best first** — smallest, self-contained UI; proves the hardened flow end-to-end. |
| #42 | open · assigned | lemon.living SEO | `docs/` marketing site; non-app. |
| #43 | open · assigned | New-Issue button uses older "@lemon" | Small fix. |
| ~~#44~~ | **closed** | Hang/Spin high CPU | Shipped in #47 — skip. |
| #45 | open · **unassigned** | Docs: `llms.txt` + teach the self-monitoring/review model | `--add-assignee frkline` first. |
| #46 | open · **unassigned** | Concurrency: queue/layer multiple 🍋 issues | `--add-assignee` first. **Run solo** — it's *about* parallel-worktree conflicts; don't dogfood it alongside another live 🍋. |

Recommended order: **#41** (clean proof) → #43 → #42/#45 (docs) → #46 (solo, careful).

## 7. Capture what you learn

Every run tends to surface a Lemon bug. File it (`gh issue create`), and record the
non-obvious root cause in `memory/` (the version-controlled graph) and/or the private
cross-session memory. This session produced #44/#39/#40 (shipped in #47) and #48 this
way. Cross-link related issues.
