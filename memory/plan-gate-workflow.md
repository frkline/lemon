---
title: Plan-gate workflow (two-session, human-approved plan)
type: decision
status: proposed
date: 2026-06-27
issue: 11
related: [[../WORKFLOW_DESIGN]]
---

The target workflow for 🍋-tagged issues is **plan-first with two human gates**:
Claude proposes a plan you approve before any code is written, an autonomous build,
then a result you approve before a PR opens. Full spec: `WORKFLOW_DESIGN.md` at the
repo root. **Not yet implemented** — the shipped flow is still fire-straight-into-auto
(`WorktreeRunner.run`).

Settled decisions (do not re-litigate without a reason):

- **Two sequential `claude` sessions, same worktree/branch, bridged by a committed
  `PLAN.md`.** Plan session (`--permission-mode plan`) writes/commits `PLAN.md` and
  stops; a *fresh* auto session reads it and builds. Chosen over single-session
  mode-switching for clean build context, and because it dissolves the
  remote-control / ExitPlanMode-picker approval uncertainty — approval becomes a
  signal to *Lemon* to launch session 2.
- **Plan is posted into the issue** with a `Lemon Plan` marker (review surface +
  approval anchor + PR material).
- **Claude opens the PR** at the result gate; Lemon writes its own action log to
  `.lemon/journal.md` in the worktree for Claude to fold in.
- **State detection via project-local hooks** (Stop/Notification → sentinel files),
  not log-scraping.
- **Gemma stays narrow**: classify permission pickers + summarize the journal. Not
  plan-approval orchestration, not sub-agent guidance.
- Two new `SessionStatus` cases (`.planReview`, `.resultReview`) overload the public
  🍋 Waiting label; popover disambiguates.

**Why:** Frank's "the key workflow to get right" — the whole point of Lemon. The
two-session shape is load-bearing: it trades plan-phase conversation context (captured
in `PLAN.md`) for clean build context, reuse of the existing re-trigger machinery, and
freedom from the undocumented in-session mode-switch mechanics.

**How to apply:** Run the **Phase 0 spike** before implementing — does plan mode halt
cleanly after writing `PLAN.md`? Stop-hook sentinel mechanics? (undocumented corners).
Phase 1 (plan gate, desk popover channel) is the keystone. Flip `status: active` once
Phase 1 lands.
