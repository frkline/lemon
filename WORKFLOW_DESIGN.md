# Lemon Plan-Gate Workflow — Design

**Status:** Proposal. Phase 0 spike **done** (2026-06-27) — core mechanics validated;
implementation not started. The shipped flow is still fire-straight-into-auto.

**Owner:** Frank · **Last updated:** 2026-06-27 · **Tracking:** issue #11

---

## Goal

Turn a 🍋-tagged issue into a **plan you approve before any code is written**, then an
autonomous build, then a **result you approve before a PR opens** — with the plan,
screenshots, and a record of what Lemon did bundled into the PR.

Two deliberate human gates:

1. **Plan gate** — Claude proposes; you approve before it builds.
2. **Result gate** — Claude finishes; you approve before the PR opens.

Everything else is autonomous. The plan-mode pass also gives Claude a cheap chance to
**reject a malformed issue** before any commitment.

---

## Relationship to issue #11

This is the design for **#11** ("Plan-first session: plan mode → confirm → user-approved
plan → auto execution"). It **resolves #11's central open question** — "one `claude`
invocation switching `--permission-mode` mid-stream, or two invocations sharing state via
`--resume`?" — in favour of **one session that switches mode at the approval picker** (the
spike confirmed this is a single clean keystroke; see below).

Two #11 phases are **designed but not yet detailed** in the flow and remain to-do:

- **Issue triage / reject (#11 Phase 1).** The plan pass first judges whether the issue is
  clear / unambiguous / non-duplicate / unblocked; if not, it posts a clarifying comment,
  sets 🍋 Waiting, and exits without touching code.
- **Confirm screen with editable fields (#11 Phase 2).** Before the plan itself, surface
  issue summary + repos/branches + target PR branch for accept / edit / reject.
- **"Autopilot" opt-out (#11 acceptance).** A per-issue/label escape hatch that skips both
  gates for trivial work — see Cost below for why this matters.

---

## Phase 0 spike — results (2026-06-27)

Ran a real `claude --permission-mode plan` session in a throwaway git repo inside tmux,
with hooks capturing every `PreToolUse` / `PermissionRequest` / `Stop` / `Notification`
payload. Findings — these are now **settled facts the design rests on**:

| # | Finding | Consequence for the design |
|---|---|---|
| 1 | **Hooks fire normally in plan mode** — every payload stamped `"permission_mode":"plan"`. | Sentinel-based state detection works in plan mode. |
| 2 | **Plan mode is genuinely read-only** — `calc.py`/`README.md` untouched; Claude only explored. | The "touches no source" guarantee is real; no extra guardrail needed. |
| 3 | **Claude Code auto-writes the plan to a file** at `~/.claude/plans/<auto-slug>.md` — no prompting. | We don't ask Claude to save the plan; it already does. |
| 4 | **The ExitPlanMode hook payload carries both** `planFilePath` **and** the full `plan` markdown inline. | Lemon captures the plan deterministically at the moment it's ready — read the file or take the inline text. |
| 5 | The plan filename has a **random suffix** (`…-majestic-glacier.md`) — unpredictable. | Lemon must read `planFilePath` **from the hook payload**, not guess the filename. |
| 6 | **A capture-only `PermissionRequest` hook (emits no decision) leaves the interactive picker up** and the session parks, waiting. | This is the gate mechanism: hook captures + signals, picker stays live for a human to answer. |
| 7 | The approval picker's first option is **"1. Yes, and use auto mode"** — approve + switch to auto in one keystroke, same session. | Single-session plan→auto is a clean `send-keys "1"`. No relaunch needed. |
| 8 | A **folder-trust prompt** ("Is this a project you trust?") fires on first `claude` launch in a new dir, blocking until answered. | Lemon must **pre-trust** each worktree dir, or the session hangs before it starts. |
| 9 | One plan pass pushed the Claude Max **session limit to 94%**. | Plan-first is ~2× Claude usage per issue. Real cost; motivates the autopilot opt-out. |

Captured approval picker, verbatim:

```
Claude has written up a plan and is ready to execute. Would you like to proceed?
❯ 1. Yes, and use auto mode
  2. Yes, manually approve edits
  3. No, refine with Ultraplan on Claude Code on the web
  4. Tell Claude what to change
```

---

## Where we are today

`WorktreeRunner.run()` launches straight into auto:

1. 🍋 picked up → worktree setup → `writeContext` → label → 🍋 In Progress
2. `claude --permission-mode auto --remote-control -- 'Read LEMON_CONTEXT.md … Use /loop'`
3. `pollUntilDone` watches labels every 10s; **Claude** sets 🍋 Waiting / 🍋 Complete
4. On Complete → single Lemon Report comment → cleanup

No plan gate, no result gate. `SessionStatus.planning` means "worktree is being set up,"
not "a plan awaits approval." Gemma's only live role is classifying permission pickers.

---

## Core design decisions

### 1. One session that switches mode at the approval picker (recommended)

A 🍋 issue runs as **a single `claude` session launched in plan mode** that, on approval,
switches to auto in the same session — retaining full context.

- Launch `claude --permission-mode plan --remote-control -- '<kickoff>'`.
- Claude explores (read-only) and calls ExitPlanMode. Our `PermissionRequest` hook
  **captures the plan and writes a sentinel but emits no decision**, so the picker parks
  live (spike finding #6).
- Lemon reads `planFilePath`, posts the plan to the issue, flips to 🍋 Waiting /
  `.planReview`, and surfaces the gate.
- On human approval, Lemon `send-keys "1"` ("Yes, and use auto mode") — the session
  switches to auto in place and starts implementing (#7).

Why this over two sessions: the spike removed the only reason to split. The plan→auto
transition is one clean keystroke, not a messy mid-stream switch, and the plan is captured
either way via `planFilePath`. One session is simpler to build (no relaunch, no worktree
state to re-establish) and keeps the planning context for the build.

**Context hygiene** — the goal that motivated two sessions — is met *within* the session
via sub-agents during the build (instructed in `LEMON_CONTEXT.md`) and the plan file as an
anchor, rather than by discarding the session.

> **Alternative: two sessions** (kept on record). The hook *denies* the exit; Lemon
> captures `planFilePath`, tears down the session, and launches a fresh
> `--permission-mode auto` session that reads the plan. Buys exactly one thing single can't
> — a **clean build context** — at the cost of a relaunch and replayed worktree state. It
> also tears down the parked session, which sidesteps the concurrency note below. Revisit
> only if carried planning context proves to pollute builds in practice.

### 2. The plan is captured from `planFilePath`, posted into the issue

Claude Code writes the plan to disk itself; the ExitPlanMode hook hands Lemon the path
(#3–#5). Lemon reads it and posts it as an issue comment tagged with a **`Lemon Plan`
marker**. That comment does triple duty: async review surface, approval anchor (a human
comment after the marker is feedback/approval — same mechanism as re-trigger), and PR
material later. Lemon keeps a copy in the worktree (`PLAN.md`) for the PR body.

### 3. Input injection is the one primitive

Every gate reduces to getting a go/feedback signal to Lemon, which Lemon turns into a
keystroke. Channels, in priority order:

1. **Lemon popover** (primary — you're at the Mac mini): shows the plan, "Approve & run"
   → `send-keys "1"`.
2. **Tracker comment** (away path): comment "approved" / feedback on the issue → Lemon
   relays it (`send-keys "1"`, or `send-keys "4"` + the feedback to re-plan).
3. **Remote control**: push notifications throughout, and answering ordinary questions
   during the auto build. Whether it can answer the ExitPlanMode picker itself is
   recorded-but-not-relied-on (the popover/comment channels cover approval regardless).

Lemon stays **observer + relay**, never an approval orchestrator. Claude drives its own
label transitions; Gemma routes but does not decide the gate (see §6).

### 4. Claude opens the PR

At the result gate, Claude (still alive in the same session) assembles the PR body —
reading `PLAN.md`, the Lemon-written journal, and `.lemon/screenshots/` from the worktree —
and runs `gh pr create` on approval. Lemon writes its journal to a file *in the worktree*
so Claude folds it in directly; no post-hoc body editing by Lemon.

### 5. State detection via hooks, not log-scraping

Lemon writes a project-local `.claude/settings.json` into each worktree (the way it already
pre-merges `.mcp.json`) emitting sentinel files. The spike proved these fire (#1). This is
the deterministic, robust path and largely retires the line-count silence detector.

### 6. Gemma routes the gate; it does not decide it

The plan-approval picker is the **human gate** — Gemma must never auto-answer it. Two
layers ensure this:

- **Primary (deterministic):** the ExitPlanMode hook sentinel tells Lemon "this is the
  plan gate." While in `.planReview`, Lemon **does not invoke Gemma's auto-answer at all** —
  it waits for a human signal. (In the spike, Gemma didn't answer the picker simply because
  the raw session wasn't Lemon-tracked; in the real flow it's suppressed *by design*.)
- **Defensive:** add a worked example to `LocalLLM.classify()` so that *if* Gemma is ever
  fed the plan-approval picker, it classifies it as **halt-for-human** (a new state),
  rather than picking an option. This is #11's "Gemma must recognize plan-mode prompts as
  different from auto-mode prompts."

During the **auto build**, Gemma's existing job is unchanged: auto-answer routine pickers
(Bash perms, edits) so the build doesn't stall.

---

## State machine

Public labels stay the coarse four. Internal `SessionStatus` gets richer so the popover
shows exactly where each session sits.

| Phase | Label | `SessionStatus` | Detected by |
|---|---|---|---|
| Tagged | 🍋 | — | Trigger poll |
| Planning | 🍋 In Progress | `.planning` | Lemon launches plan-mode session |
| Plan review | 🍋 Waiting | `.planReview` *(new)* | **ExitPlanMode hook sentinel** |
| Executing | 🍋 In Progress | `.executing` | `send-keys "1"` accepted |
| Question | 🍋 Waiting | `.waiting` | **Notification hook sentinel** |
| Result review | 🍋 Waiting | `.resultReview` *(new)* | Build-done signal / Stop hook |
| Complete | 🍋 Complete | `.reviewing` → `.done` | PR opened; cleanup |

`.planReview` and `.resultReview` are new `SessionStatus` cases; both overload the public
🍋 Waiting label, disambiguated in the popover. New smoke-test scenarios for each.

---

## End-to-end flow (single-session)

```
🍋 added
  └─ Lemon: git worktree add /tmp/lemon-{slug} -b lemon/{slug} origin/main
     PRE-TRUST the worktree dir            ← spike #8 (else claude hangs on trust prompt)
     write LEMON_CONTEXT.md + .claude/settings.json (hooks)
     label → 🍋 In Progress, status .planning

  ┌─ ONE SESSION, launched in plan mode ─────────────────────────────┐
  │ claude --permission-mode plan --remote-control -- '<kickoff>'      │
  │ kickoff: read LEMON_CONTEXT.md; triage the issue (#11 P1, TBD);    │
  │   explore; propose a plan via ExitPlanMode. Don't implement.       │
  │                                                                    │
  │ Claude explores (read-only) → calls ExitPlanMode →                 │
  │   PermissionRequest(ExitPlanMode) hook:                            │
  │     • read tool_input.planFilePath / .plan                         │
  │     • write /tmp/lemon-{slug}-plan-ready sentinel (+ copy plan)    │
  │     • emit NO decision  → picker parks live (spike #6)             │
  └────────────────────────────────────────────────────────────────────┘
     └─ Lemon poll sees sentinel:
        read planFilePath → write worktree PLAN.md → post to issue (Lemon Plan marker)
        label → 🍋 Waiting, status .planReview ; remote push "plan ready for {id}"
        Gemma auto-answer SUPPRESSED while .planReview (§6)

  ── PLAN GATE ──  approve: popover "Approve & run" | comment "approved" | remote reply
     approve  → send-keys "1"  (Yes + auto mode)        → SAME session, now auto
     feedback → send-keys "4" + text (or re-plan)       → revised plan, advance marker
                                                            stays .planReview

  ┌─ same session, now in auto mode (context retained) ───────────────┐
  │ implements the approved plan; Use /loop                            │
  │ Gemma auto-answers routine pickers (existing)                      │
  │ Notification hook → awaiting-input sentinel for genuine mid-build Qs│
  │ label → 🍋 In Progress, status .executing                          │
  │ completion checklist: capture screenshots → .lemon/screenshots/;   │
  │   DO NOT open the PR — summarize results and wait                  │
  └────────────────────────────────────────────────────────────────────┘
     └─ build done → status .resultReview

  ── RESULT GATE ──  popover: diff summary · screenshots · "What Lemon did" (Gemma) ·
     branch-confirm "Open PR" button
     approve → Claude assembles PR body (PLAN.md + .lemon/journal.md + screenshots);
       gh pr create
     label → 🍋 Complete, status .reviewing → .done ; Lemon cleans up worktree
```

---

## Hooks Lemon installs (per-worktree `.claude/settings.json`)

| Event | Matcher | Action |
|---|---|---|
| `PermissionRequest` | `ExitPlanMode` | Read `planFilePath`/`plan`; write `…-plan-ready` sentinel + plan copy; **emit no decision** (park the picker). |
| `Notification` | — | Write `…-awaiting-input` sentinel (genuine mid-build question). |
| `Stop` | — | Write `…-stopped` sentinel (session idle/ended — build-done candidate, early-exit). |

Open implementation detail (spike #8 + scoping): confirm the cleanest way to **pre-trust**
a worktree and scope this hooks config without disturbing the user's global Claude config.
Candidates: a `--add-dir`/trusted-dirs entry, or seeding the project's trust state. The
existing early-exit sentinel `/tmp/lemon-exit-{slug}` stays.

> Note: the `PreToolUse` write-allowlist idea from earlier drafts is **dropped** — plan
> mode's native read-only guarantee (spike #2) makes it unnecessary.

---

## Artifacts → PR

All live in the worktree:

| Artifact | Written by | Used for |
|---|---|---|
| `PLAN.md` | Lemon, from `planFilePath` | Popover review · issue comment · PR "Plan" section |
| `.lemon/screenshots/` | Auto phase (Claude) | Result-gate popover · PR (mock-operation evidence) |
| `.lemon/journal.md` | **Lemon** | PR "What Lemon orchestrated" section |

- **`.lemon/journal.md`** is Lemon's authoritative record of *its own* actions: Gemma
  verdicts, relayed approvals, picker answers, phase timings. Claude can't self-report what
  Gemma did; Lemon owns this file.
- At the result gate, **Gemma summarizes the journal** into the PR section. Needs a larger
  generation budget than the 300-token / 80-char classify path — a separate call, possibly
  chunked.
- **Screenshot hosting into the PR is source-specific** (commit into branch so GitHub
  renders inline; Linear's upload API). Mirror the `IssueSourceClient` pattern. Text + diff
  reliably; screenshots best-effort (see Operational requirements).

---

## Gemma's role (narrowed, explicit)

Keep:
- **Classify routine permission pickers** in the auto phase (existing).

Add:
- **Halt-for-human on the plan-approval picker** — defensive example so Gemma never
  auto-answers the gate (§6).
- **Summarize `.lemon/journal.md`** into the "What Lemon orchestrated" PR section.

Explicitly *not* Gemma's job:
- Deciding plan approval → the input-injection primitive + the gate.
- Deciding sub-agent usage for context hygiene → a `LEMON_CONTEXT.md` prompt instruction.
- Nudging screenshots → a completion-checklist item Claude self-prompts on.

---

## Operational requirements (mostly surfaced by the spike)

- **Pre-trust every worktree** before launching `claude`, or it hangs on the folder-trust
  prompt (#8). Hard blocker — needed for *any* plan-mode launch.
- **Capture `planFilePath` from the hook payload** — never guess the plan filename (#5).
- **Cost / session limits (#9).** Plan-first is ~2× Claude usage per issue (two phases).
  On a Max plan this is material — one spike pass hit 94%. Mitigations: the **autopilot
  opt-out** for trivial issues (skip the plan gate), and surfacing remaining session
  budget in the popover so a user isn't surprised mid-build.
- **Screenshots are best-effort.** Capturing mock-operation screenshots for an arbitrary
  user project is hard (run the app? Playwright? platform-specific). Lemon's own UI has the
  smoke harness; arbitrary projects don't. Promise text + diff reliably.

---

## Failure modes & hardening

- **Plan never approved.** Single-session: the session sits parked at the picker, holding a
  live process **and a concurrency slot**. Need either (a) "parked ≠ active" accounting so
  gated sessions don't block the max-2 build limit, or (b) a park timeout. (The two-session
  alternative avoids this by tearing down.) Surface staleness in the popover; optional
  notify after N hours; no auto-discard.
- **Plan rejected / feedback.** `send-keys "4"` + feedback (or re-plan); re-post the revised
  plan, **advancing the marker**. Stays `.planReview` — never executes without a go.
- **Marker advancement.** Live comment relay sharpens the existing known gap
  (`hasNewComment` re-fires on already-handled comments). **Must** post a fresh marker
  comment after each plan revision / relayed interaction. In scope for the relay work.
- **Build fails after approval.** Resume from the committed `PLAN.md`; do not re-plan.
- **Result gate holds a live session.** Acceptable (brief, idle); the parked-session
  accounting/timeout above applies here too.

---

## Phasing

- **Phase 0 — spike. ✅ DONE (2026-06-27).** Validated plan-mode read-only, hooks fire,
  `planFilePath` capture, parked-picker gate, one-keystroke plan→auto, folder-trust blocker,
  ~2× cost. See "Phase 0 spike — results."
- **Phase 1 — plan gate, desk channel (keystone).** Pre-trust worktrees; install hooks;
  ExitPlanMode sentinel → capture `planFilePath` → post plan to issue → `.planReview` →
  popover "Approve & run" → `send-keys "1"`. Suppress Gemma in `.planReview`. Delivers the
  core human-in-the-loop plan approval.
- **Phase 1.x — #11 extras.** Issue triage/reject pass; confirm screen with editable
  fields; autopilot opt-out.
- **Phase 2 — approval channels.** Tracker-comment approval (away path) + remote-control
  notifications; **fix marker advancement**; defensive Gemma halt example.
- **Phase 3 — result gate.** Hold the PR; present results + branch confirm; approve →
  Claude opens PR. Parked-session accounting/timeout.
- **Phase 4 — artifacts + Gemma summary.** `PLAN.md` / screenshots / journal → PR body;
  Gemma "What Lemon did" section; source-specific screenshot hosting.

Each phase ships value independently. Phase 1 is the keystone.

---

## Open decisions

1. **Session model** — single-session (recommended; spike-validated) vs the two-session
   alternative for clean build context. *Lean: single.*
2. **Parked-session policy** — accounting fix vs timeout vs both, for sessions idling at a
   gate (single-session only).
3. **Autopilot trigger** — a label (e.g. `🍋 auto`) vs a per-workspace default, for
   skipping the plan gate on trivial issues.
4. **Pre-trust mechanism** — the cleanest way to mark a worktree trusted (spike to-do).
