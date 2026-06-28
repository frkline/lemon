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

- **Single `claude` session that switches mode at the approval picker** (recommended,
  spike-validated). Launch in `--permission-mode plan`; on approval Lemon `send-keys "1"`
  ("Yes, and use auto mode") → same session continues in auto with context retained. The
  two-session alternative (fresh auto session reading the plan) is kept on record only for
  if carried context pollutes builds. See [[claude-code-plan-mode]] for the mechanics.
- **Plan captured from `planFilePath`** in the ExitPlanMode hook payload (Claude Code
  auto-writes the plan file), then posted to the issue with a `Lemon Plan` marker.
- **Claude opens the PR** at the result gate; Lemon writes `.lemon/journal.md` in the
  worktree for Claude to fold in.
- **State detection via project-local hooks** (PermissionRequest/Notification/Stop →
  sentinels), not log-scraping.
- **Gemma routes, never decides, the gate**: suppressed while `.planReview`; plus a
  defensive halt-for-human classify example. Still auto-answers routine pickers in auto.
- Two new `SessionStatus` cases (`.planReview`, `.resultReview`) overload 🍋 Waiting.
- **Worktrees must be pre-trusted** or `claude` hangs on the folder-trust prompt.

**Implemented + sandbox-validated 2026-06-27** (single session, plan mode → gate → auto):
`WorktreeRunner` launches `--permission-mode plan` for fresh sessions + writes a
`.claude/settings.json` ExitPlanMode hook; `planGatePhase` waits for the plan sentinel
(`/tmp/lemon-plan-{slug}.md`, written by the hook or fake-claude), posts the plan to the
issue, parks at `.planReview`; `Orchestrator.resolveGate` (popover or `approve_gate` MCP)
send-keys "1" + writes `/tmp/lemon-gate-{slug}`; the same session continues into the build.
`make sandbox-test` asserts the whole lifecycle (6/6). **Still pending:** real-claude
validation (folder pre-trust spike #8, live hook), result gate (`.resultReview` UI exists
but no orchestration), #11 issue-triage + confirm-screen phases, autopilot opt-out.

**Why:** Frank's "the key workflow to get right" — the whole point of Lemon.
**How to apply:** Phase 1 (plan gate, desk popover channel) is the keystone. Watch the
~2× Claude session cost (one plan pass hit 94% of a Max limit) — motivates an autopilot
opt-out for trivial issues. Build the [[sandbox-iteration-loop]] first so the workflow can
be tuned for free and side-effect-free. Flip `status: active` once Phase 1 lands.
