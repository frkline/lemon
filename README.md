# 🍋 Lemon

A personal workflow orchestration menu-bar app for **Claude Code + Linear**, leveraging **Gemma 4 on device**. Made for the Mac mini sitting on your desk. Tag a Linear issue with 🍋 — Lemon spins up a git worktree, launches your `claude` CLI in Terminal, monitors progress via Linear labels, and posts a report when the PR is ready.

The intelligence is Claude Code (your login) and a small local Gemma 4 classifier watching the pane. Lemon itself is glue.

**lemon.living** — direct download, not App Store.

### What Lemon is (and isn't)

| ✅ It is | ❌ It isn't |
|---|---|
| A **menu-bar orchestrator** that decides when to start Claude Code | An AI agent product — the agent is Claude Code |
| Glue between **your Linear queue** and **your Claude Code CLI** | A Claude reseller — Lemon never proxies your API traffic |
| A **local Gemma 4 classifier** for obvious-confirmation auto-accept and unstick-dumb-prompts | A multi-tenant SaaS |
| Built for **one developer** running it | A competitor to Anthropic, Linear, or anything else |

### Bonus: nest `/loop` inside

Lemon is itself a hand-coded `/loop` — `goal = ship a PR for this Linear issue`. The Orchestrator polls, Gemma watches the pane, the session keeps going until 🍋 Complete fires. That same pattern is broadly useful inside a session too, especially for work that benefits from iteration over one-shot:

- **Polish** — UI / docs / a tricky code path: try, look, refine
- **Reviews** — diffs, PRs, modules: one finding per tick
- **Refactors** — when you can't enumerate every call site upfront
- **Bug-hunting sweeps** — fix one, run tests, find the next
- **Test backfill** — write one, watch it pass, find the next gap
- **Exploration** — when the next move depends on what the last move just told you

Each tick is small, scoped, verifiable. Same reason Lemon's outer loop works. Write your team's `LEMON.md` to tell Claude to lean on `/loop` whenever the issue calls for it — you get nested iteration: Lemon iterates the Linear queue, Claude iterates inside each ticket. (This README, the docs site, and most of the bug fixes in this repo were built by running `/loop` against an open-ended "drive Lemon to fully baked" goal for an hour.)

---

## How it works

1. **Label** a Linear issue with 🍋
2. **Lemon.app** picks it up on the next poll (15s when active, 45s when idle)
3. A **git worktree** is created at `/tmp/lemon-{identifier}` from your local repo
4. A **Terminal window** opens running `claude --enable-auto-mode --remote-control`
5. Claude works the issue, sets Linear labels as it goes, and opens a PR
6. When Claude sets **🍋 Complete**, Lemon posts a report comment to Linear and cleans up
7. Reply to the Lemon report comment to re-trigger a revision — Lemon reuses the branch

## Linear labels

Lemon creates and manages these automatically:

| Label | Set by | Meaning |
|-------|--------|---------|
| `🍋` | You | Trigger — Lemon picks this up |
| `🍋 In Progress` | Lemon | Worktree active, Claude running |
| `🍋 Waiting` | Claude | Paused, needs your input |
| `🍋 Complete` | Claude | PR open, report posted |

## Setup

### 1. Prerequisites

```sh
brew install gh
gh auth login

# Claude Code CLI — install from claude.ai/code, then:
claude login
```

### 2. Install Lemon.app

Download from [lemon.living](https://lemon.living) and launch it.

### 3. Onboarding (3 steps)

**Step 1 — Linear:** Paste your Linear API key (from linear.app → Settings → API). Lemon verifies it and fetches your identity automatically.

**Step 2 — Workspace:** Add your local repo paths and their Linear issue prefixes (e.g. `/Users/you/Projects/myapp` → `LEM`). Lemon uses the prefix to route issues to the right repo.

**Step 3 — Done:** Lemon detects your Claude Code auth and starts polling.

---

## Architecture

```
Lemon.app (macOS 26, unsandboxed)
  └── polls Linear for 🍋-labeled issues
  └── WorktreeRunner (one per issue)
        ├── git worktree add /tmp/lemon-{id} -b lemon/{id} origin/main
        ├── writes LEMON_CONTEXT.md (issue details + completion checklist)
        ├── updates labels: 🍋 → 🍋 In Progress
        ├── open -a Terminal launcher.sh  →  claude --enable-auto-mode --remote-control
        ├── polls Linear every 10s for label changes
        └── on 🍋 Complete: post report, remove worktree
```

## Requirements

- macOS 26 (Darwin 25.x)
- `gh` CLI, authenticated (`gh auth login`)
- Claude Code CLI, authenticated (`claude login`)
- A Linear workspace with API access
