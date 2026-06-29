---
title: Claude Code plan-mode mechanics (empirical, from Phase 0 spike)
type: reference
status: active
date: 2026-06-27
related: [[plan-gate-workflow]]
---

Durable facts about how `claude --permission-mode plan` behaves, established by running a
real session in tmux with hooks capturing every payload (2026-06-27, claude v2.1.195).

> **Note (2026-06-28, #76): Lemon no longer uses plan mode.** The plan gate was reworked to
> launch in `--permission-mode auto` and approve via AskUserQuestion, symmetric with the
> result gate — see [[plan-gate-workflow]]. The facts below are kept as reference, but the
> brittleness they document is exactly why we moved off: the approval picker (item below) is
> a human pick among version-coupled options (hard-coded "1" drifts across claude versions),
> phone approval over remote-control bypassed Lemon's keystroke, and plan mode's read-only
> nature was inherited by subagents (Explore prompted during planning).

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

**How to apply (historical — superseded by #76):** Lemon's per-worktree
`.claude/settings.json` hooks read `planFilePath` on the `ExitPlanMode` PermissionRequest
and wrote a sentinel; Lemon posted the plan and parked until a human answered, then
`send-keys "1"`. This is no longer how the plan gate works — claude now writes the plan
sentinel directly in auto mode and approval is an AskUserQuestion picker (resolveGate
send-keys "1"/"2"). See [[plan-gate-workflow]].
