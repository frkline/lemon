---
title: Claude Code plan-mode mechanics (empirical, from Phase 0 spike)
type: reference
status: active
date: 2026-06-27
related: [[plan-gate-workflow]]
---

Durable facts about how `claude --permission-mode plan` behaves, established by running a
real session in tmux with hooks capturing every payload (2026-06-27, claude v2.1.195).
The plan-gate design depends on these.

- **Hooks fire in plan mode** — `PreToolUse`, `PermissionRequest`, `Stop`, `Notification`
  all fire, each payload stamped `"permission_mode":"plan"`.
- **Plan mode is genuinely read-only** — Claude explores (Read/Bash/ToolSearch) but writes
  no source files. The only write is Claude Code persisting its own plan file.
- **Claude Code auto-writes the plan** to `~/.claude/plans/<auto-slug>.md` with a random
  suffix (e.g. `…-majestic-glacier.md`) — unprompted.
- **The ExitPlanMode hook payload carries `planFilePath` AND the full `plan` markdown
  inline.** Read `planFilePath` from the hook — do NOT guess the filename (random suffix).
- **A capture-only `PermissionRequest` hook (emits no decision) leaves the interactive
  approval picker up** and the session parks waiting. This is the gate mechanism.
- **Approval picker options** (verbatim): `1. Yes, and use auto mode` / `2. Yes, manually
  approve edits` / `3. No, refine with Ultraplan on Claude Code on the web` / `4. Tell
  Claude what to change`. Option 1 = clean one-keystroke plan→auto switch, same session.
- **Folder-trust prompt** ("Is this a project you trust?") fires on first `claude` launch
  in a new dir and blocks until answered — worktrees must be pre-trusted.
- **Cost:** one plan pass pushed a Claude Max session to ~94% — plan-first is ~2× usage.

**How to apply:** Lemon's per-worktree `.claude/settings.json` hooks read `planFilePath`
on the `ExitPlanMode` PermissionRequest and write a sentinel; Lemon posts the plan and
parks until a human answers, then `send-keys "1"`. See [[plan-gate-workflow]].
