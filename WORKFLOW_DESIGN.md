# Lemon Plan-Gate Workflow — Design

**Status:** Proposal / not yet implemented. This describes the target workflow for
human-in-the-loop, plan-first orchestration. The shipped flow today is
fire-straight-into-auto (see "Where we are today"). Phase 0 spike must validate the
undocumented corners before code lands.

**Owner:** Frank · **Last updated:** 2026-06-27 · **Tracking:** issue #11

---

## Relationship to issue #11

This doc is the design for **#11** ("Plan-first session: plan mode → confirm →
user-approved plan → auto execution"). It **resolves #11's central open question** —
"one `claude` invocation switching `--permission-mode` mid-stream, or two invocations
sharing session state via `--resume`?" — in favour of **two sessions bridged by a
committed `PLAN.md`** (clean build context; no mid-stream mode switch to negotiate).

Two parts of #11 are **not yet folded into the flow below** and remain to-do:

- **Issue triage / reject (#11 Phase 1).** The plan session should first judge whether
  the issue is clear / unambiguous / non-duplicate / unblocked; if not, post a clarifying
  comment, set 🍋 Waiting, and exit without touching code.
- **Confirm screen with editable fields (#11 Phase 2).** Before the plan itself, surface
  issue summary + repos/branches + target PR branch for the user to accept/edit/reject.

Both slot in ahead of the plan gate; track them as Phase 1.x once the keystone lands.

---

## Goal

Turn a 🍋-tagged issue into a **plan you approve before any code is written**, then an
autonomous build, then a **result you approve before a PR opens** — with the plan,
screenshots, and a record of what Lemon did bundled into the PR.

Two deliberate human gates:

1. **Plan gate** — Claude proposes; you approve before it builds.
2. **Result gate** — Claude finishes; you approve before the PR opens.

Everything between and around the gates is autonomous.

---

## Where we are today

`WorktreeRunner.run()` launches straight into auto mode:

1. 🍋 picked up → worktree setup → `writeContext` → label → 🍋 In Progress
2. `claude --permission-mode auto --remote-control -- 'Read LEMON_CONTEXT.md … Use /loop'`
3. `pollUntilDone` watches labels every 10s; **Claude** sets 🍋 Waiting / 🍋 Complete
4. On Complete → single Lemon Report comment → cleanup

There is no plan gate, no result gate. `SessionStatus.planning` means "worktree is being
set up," not "a plan awaits approval." Gemma's only live role is classifying permission
pickers in auto mode.

---

## Core design decisions

### 1. Two sessions, bridged by a committed `PLAN.md`

A 🍋 issue runs as **two sequential `claude` sessions in the same worktree/branch**:

- **Plan session** (`--permission-mode plan`): explores, writes a thorough `PLAN.md`,
  commits it, and stops. No code changes.
- **Auto session** (`--permission-mode auto`): a *fresh* session that reads the approved
  `PLAN.md` and builds.

Why two sessions instead of one session that switches modes after approval:

- **Clean build context.** Session 2 starts on just the plan — no exploration cruft.
  This is the "keep context clean" goal, achieved structurally rather than by prompting.
- **Dissolves the approval-mechanism uncertainty.** There is no in-session mode
  transition to negotiate (no ExitPlanMode picker to answer, no contested
  remote-control-approves-a-picker question). The plan session ends; approval is just a
  signal that tells **Lemon** to launch session 2 — which Lemon fully controls.
- **Reuses the re-trigger machinery.** "Post artifact → wait for human signal → launch
  next session" is exactly today's Lemon Report → human reply → re-launch flow.
- **Solves concurrency for free.** A session waiting at the plan gate is *torn down*, not
  idling. It holds no build slot. No concurrency-accounting split needed.

**Cost:** the plan-phase *conversation* context is lost between sessions. Mitigation is
the point — `PLAN.md` must capture key file paths and findings so session 2 doesn't
re-derive them. Forcing that to be written down makes the plan better.

The **worktree and branch persist across both sessions** (`PLAN.md` is committed on the
branch). Only the `claude`/tmux process is torn down at the gate.

### 2. The plan is posted into the issue

When the plan session finishes, Lemon posts `PLAN.md` as a comment on the issue, tagged
with a **`Lemon Plan` marker**. This comment does triple duty:

- **Async review surface** — review the plan from anywhere, not just the desk.
- **Approval anchor** — a human comment *after* the marker is the approval/feedback
  signal (same mechanism as re-trigger's reply-after-Lemon-Report).
- **PR material** — the approved plan flows into the PR body later.

### 3. Input injection is the one primitive

Every gate reduces to "get a go/feedback signal to Lemon." Channels, in priority order:

1. **Lemon popover** (primary — you're at the Mac mini): shows `PLAN.md`, "Approve & run"
   button → Lemon launches the auto session.
2. **Tracker comment** (away path): comment "approved" (or feedback) on the issue → Lemon
   relays/acts on it. This is the real remote-approval path.
3. **Remote control**: push notifications throughout, and answering ordinary questions
   *during the auto build* (definitely supported). Not relied on for plan approval —
   between sessions there is no live session for it to talk to anyway.

Lemon stays an **observer + relay**, never an approval orchestrator. Claude drives its
own label transitions; Gemma stays a classifier.

> **Note on remote control + plan approval.** An earlier draft claimed remote control
> *cannot* approve a plan. That was an unverified inference (reasoning by analogy from
> "/plugin and /resume are local-only"). ExitPlanMode is a *permission request*, a
> different category that remote control may well handle. The two-session model makes the
> question moot, so we don't depend on the answer — but the Phase 0 spike should still
> record what actually happens.

### 4. Claude opens the PR

At the result gate, Claude (still alive in the auto session) assembles the PR body —
reading `PLAN.md`, the Lemon-written journal, and `.lemon/screenshots/` out of the
worktree — and runs `gh pr create` on approval. Lemon writes its journal to a file *in
the worktree* so Claude picks it up directly; no post-hoc body editing by Lemon.

### 5. State detection via hooks, not log-scraping

Lemon writes a project-local hooks config into the worktree (the way it already pre-merges
`.mcp.json`) emitting sentinel files for:

- **plan ready** — `Stop` hook (plan session finished writing `PLAN.md`) → sentinel
- **awaiting input** — `Notification` hook (Claude genuinely waiting) → sentinel
- **done** — `Stop` hook (auto session) → sentinel

This is the documented, robust path and largely retires the fragile line-count silence
detector. (Existing early-exit sentinel `/tmp/lemon-exit-{slug}` stays.)

---

## State machine

Public labels stay the coarse four. Internal `SessionStatus` gets richer so the popover
shows exactly where each session sits.

| Phase | Label | `SessionStatus` | Driven by |
|---|---|---|---|
| Tagged | 🍋 | — | Human |
| Planning | 🍋 In Progress | `.planning` | Lemon launches plan session |
| Plan review | 🍋 Waiting | `.planReview` *(new)* | Plan posted; awaiting approval |
| Executing | 🍋 In Progress | `.executing` | Auto session building |
| Question | 🍋 Waiting | `.waiting` | Claude paused mid-build |
| Result review | 🍋 Waiting | `.resultReview` *(new)* | Build done; awaiting PR go |
| Complete | 🍋 Complete | `.reviewing` → `.done` | PR opened; cleanup |

`.planReview` and `.resultReview` are new `SessionStatus` cases. Both overload the public
🍋 Waiting label; the popover disambiguates. New smoke-test scenarios for each.

---

## End-to-end flow

```
🍋 added
  └─ Lemon: worktree add /tmp/lemon-{slug} -b lemon/{slug} origin/main
     write LEMON_CONTEXT.md + project-local hooks config
     label → 🍋 In Progress, status .planning

  ┌─ PLAN SESSION ──────────────────────────────────────────────┐
  │ claude --permission-mode plan --remote-control -- '<kickoff>' │
  │ kickoff: explore; write a thorough PLAN.md (key file paths +  │
  │   findings so a fresh session can execute it); commit it;     │
  │   stop. Do not implement.                                     │
  │ Stop hook → /tmp/lemon-{slug}-plan-ready sentinel             │
  └───────────────────────────────────────────────────────────────┘
     └─ Lemon: read PLAN.md, post to issue w/ `Lemon Plan` marker
        label → 🍋 Waiting, status .planReview
        tear down claude/tmux session (KEEP worktree + branch)
        remote-control push: "plan ready for {id}"

  ── PLAN GATE ── (approve: popover button | comment after marker | …)
     feedback instead of approval → relaunch plan session to revise
        (loops; stays .planReview)

  ┌─ AUTO SESSION ──────────────────────────────────────────────┐
  │ same worktree/branch                                          │
  │ claude --permission-mode auto --remote-control -- '<kickoff>' │
  │ kickoff: read committed PLAN.md; implement it; Use /loop.     │
  │   When done, summarize results + capture screenshots into     │
  │   .lemon/screenshots/. DO NOT open the PR — wait.             │
  │ Gemma classifies permission pickers (existing)                │
  │ Notification hook → awaiting-input sentinel for mid-build Qs   │
  │ label → 🍋 In Progress, status .executing                     │
  └───────────────────────────────────────────────────────────────┘
     └─ build done → status .resultReview

  ── RESULT GATE ── popover shows: diff summary, screenshots,
     "What Lemon did" (Gemma), branch-confirm "Open PR" button
     approve →
       Claude (still alive): assemble PR body from PLAN.md +
       .lemon/journal.md + .lemon/screenshots/; gh pr create
     label → 🍋 Complete, status .reviewing → .done
     Lemon: cleanup worktree
```

---

## Artifacts → PR

All live in the worktree:

| Artifact | Written by | Used for |
|---|---|---|
| `PLAN.md` (committed) | Plan session (Claude) | Popover review · issue comment · PR "Plan" section |
| `.lemon/screenshots/` | Auto session (Claude) | Result-gate popover · PR (mock-operation evidence) |
| `.lemon/journal.md` | **Lemon** | PR "What Lemon orchestrated" section |

- **`.lemon/journal.md`** is Lemon's authoritative record of *its own* actions: Gemma
  verdicts, relayed approvals, picker answers, phase timings. Claude can't self-report
  what Gemma did behind the scenes; Lemon owns this file.
- At the result gate, **Gemma summarizes the journal** into the PR section. This needs a
  larger generation budget than the 300-token / 80-char classify path — a separate
  generation call, possibly chunked. (Classify constraints in `CLAUDE.md` still apply to
  the picker path.)
- **Screenshot hosting into the PR is source-specific** (commit into branch so GitHub
  renders inline; Linear's upload API). Mirror the `IssueSourceClient` pattern. Defer the
  polish — text + committed images first.

---

## Gemma's role (narrowed, explicit)

Keep:
- **Classify permission pickers** in the auto session (existing).

Add:
- **Summarize `.lemon/journal.md`** into the "What Lemon orchestrated" PR section
  (one-shot, larger budget).

Explicitly *not* Gemma's job:
- Orchestrating plan approval → input-injection primitive + the gate.
- Deciding sub-agent usage for context hygiene → a *prompt* instruction in
  `LEMON_CONTEXT.md`, not a runtime loop.
- Nudging screenshots → a completion-checklist item Claude self-prompts on.

---

## Failure modes & hardening

- **Plan never approved.** Session is torn down, so no compute leaks — but the issue sits
  in `.planReview`. Need an abandonment policy: surface staleness in the popover; optional
  notify after N hours. (No auto-discard.)
- **Plan rejected / feedback given.** Relaunch the plan session with the feedback;
  re-post a revised plan (advancing the marker). Stays `.planReview` — never flips to
  executing without a go.
- **Marker advancement.** Live comment relay sharpens the existing known gap
  (`hasNewComment` re-fires on already-handled comments). **Must** post a fresh marker
  comment after each plan revision and each relayed interaction so the marker advances.
  This is in-scope for the relay work, not deferred.
- **Build fails after approval.** Resume from the committed `PLAN.md` — do not re-plan.
- **Screenshots are best-effort.** Capturing mock-operation screenshots for an arbitrary
  user project is hard (run the app? Playwright? platform-specific). Lemon's own UI has
  the smoke harness; arbitrary projects do not. Promise text + diff reliably, screenshots
  best-effort.
- **Result gate holds a live session.** The auto session stays alive (idle) through the
  result gate so Claude can open the PR. Brief; acceptable. If review drags, the
  abandonment policy applies here too.

---

## Phasing

- **Phase 0 — spike (½ day).** In a real tmux session, prove the mechanics the design
  rests on:
  1. `--permission-mode plan` session writes `PLAN.md` and **halts cleanly**; a `Stop`
     hook writes a sentinel Lemon can watch.
  2. A fresh `--permission-mode auto` session **resumes the same worktree/branch** and
     reads `PLAN.md`.
  3. (Record-only) What remote control actually does with an ExitPlanMode-style approval.
  Much less uncertain than the single-session path — these are bread-and-butter, but the
  headless/hook corners are undocumented, so verify before building.

- **Phase 1 — plan gate, desk channel (keystone).** Plan session + Stop-hook sentinel +
  post `PLAN.md` to issue + `.planReview` + popover "Approve & run" → launch auto session.
  Delivers the core human-in-the-loop plan approval.

- **Phase 2 — approval channels.** Tracker-comment approval (away path) + remote-control
  notifications. Generalize re-trigger into live comment relay; **fix marker advancement.**

- **Phase 3 — result gate.** Hold the PR; present results + branch confirm in popover;
  approve → Claude opens PR.

- **Phase 4 — artifacts + Gemma summary.** `PLAN.md` / screenshots / `.lemon/journal.md`
  → PR body; Gemma "What Lemon did" section; source-specific screenshot hosting.

Each phase ships value independently. Phase 1 is the keystone.

---

## Open questions for the spike

1. Does `--permission-mode plan` in an interactive tmux session reliably **stop** after
   writing `PLAN.md`, or does it sit at an ExitPlanMode prompt? (Determines whether the
   kickoff says "don't call ExitPlanMode, just stop" vs. a hook denies+signals on it.)
2. Exact `Stop` / `Notification` hook payloads and how to scope a project-local hooks
   config in the worktree without disturbing the user's global config.
3. What remote control surfaces for an ExitPlanMode approval (record-only; not depended on).
