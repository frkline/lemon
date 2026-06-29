---
title: Plan-gate workflow (plan-first, two human gates)
type: decision
status: active
date: 2026-06-27
issue: 11
related: [[claude-code-plan-mode]], [[../WORKFLOW_DESIGN]]
---

The target workflow for 🍋-tagged issues is **plan-first with two human gates** (approve
the plan before code; approve the result before the PR). Full spec: `WORKFLOW_DESIGN.md`.
**Phase 0 spike done 2026-06-27; not yet implemented** — shipped flow is still
fire-straight-into-auto (`WorktreeRunner.run`).

Settled decisions (do not re-litigate without a reason):

- **Single `claude` session in auto mode the whole time** (#76, supersedes the
  plan-mode→auto transition below). Launch in `--permission-mode auto`; the kickoff prompt
  has claude triage, write its plan to the plan sentinel, post it, and raise a native
  **AskUserQuestion** picker (1 approve / 2 request changes) — exactly like the result gate.
  There is **no mode to transition out of**, so the brittle `send-keys "1" = use auto mode`
  step and its phone-approval failure modes are gone. See [[claude-code-plan-mode]].
  - *Superseded:* the original design launched `--permission-mode plan` and `send-keys "1"`
    at the ExitPlanMode picker to continue in auto. Dropped in #76 because exiting plan mode
    is a human pick among ~5 version-coupled options (hard-coded "1" drifts), phone approval
    bypassed Lemon's keystroke (stalling on the first edit prompt in `default` mode), and
    plan mode is read-only so subagents inherited it and prompted.
- **Plan written by claude directly** to the plan sentinel (the kickoff prompt instructs it
  in auto mode), then posted to the issue with a `Lemon Plan` marker. (Previously captured
  from `planFilePath` via an ExitPlanMode `PreToolUse` hook — that hook + `writePlanHooks`
  were deleted in #76.)
- **Claude opens the PR** at the result gate; Lemon writes `.lemon/journal.md` in the
  worktree for Claude to fold in.
- **State detection via project-local hooks** (PermissionRequest/Notification/Stop →
  sentinels), not log-scraping.
- **Gemma routes, never decides, the gate**: suppressed while `.planReview`; plus a
  defensive halt-for-human classify example. Still auto-answers routine pickers in auto.
- Two new `SessionStatus` cases (`.planReview`, `.resultReview`) overload 🍋 Waiting.
- **Worktrees must be pre-trusted** or `claude` hangs on the folder-trust prompt.

**Implemented + sandbox-validated 2026-06-27; reworked to auto + AskUserQuestion 2026-06-28
(#76).** Both gates now run the single session in `--permission-mode auto` and surface
approval via AskUserQuestion. `planGatePhase` waits for the plan sentinel
(`/tmp/lemon-plan-{slug}.md`, written by claude / fake-claude), posts the plan, parks at
`.planReview`; `Orchestrator.resolveGate` (popover or `approve_gate` MCP) send-keys "1"/"2"
into the picker AND writes `/tmp/lemon-gate-{slug}`, while phone approval has claude write
the gate sentinel itself; the same session continues into the build. The result gate is
opt-in via `/tmp/lemon-result-{slug}.md` — same shape. `make sandbox-test` asserts the full
two-gate lifecycle. The request-changes loop is real: resolveGate send-keys "2", claude
revises + rewrites the plan sentinel + re-raises AskUserQuestion, and `planGatePhase` loops
to the next round. **Still pending:** real-claude end-to-end validation (folder pre-trust,
live AskUserQuestion over remote-control), autopilot opt-out tuning.

**Why:** Frank's "the key workflow to get right" — the whole point of Lemon.
**How to apply:** Phase 1 (plan gate, desk popover channel) is the keystone. Watch the
~2× Claude session cost (one plan pass hit 94% of a Max limit) — motivates an autopilot
opt-out for trivial issues. Build the [[sandbox-iteration-loop]] first so the workflow can
be tuned for free and side-effect-free. Flip `status: active` once Phase 1 lands.
