---
title: Long-tail omnibus (issues ≥ 46) — lifecycle, queue, GC, glyph
type: decision
status: active
date: 2026-06-28
issue: 46, 48, 51, 53, 54, 55, 57, 64, 67
related: [[plan-gate-workflow]], [[sandbox-iteration-loop]], [[next-session-playbook]]
---

One omnibus PR cleared the post-build/lifecycle friction long-tail. Key decisions
(the parts not obvious from the diff):

- **#46 concurrency queue.** A real, visible FIFO queue: `SessionStatus.queued`,
  over-limit triggers become tracked `.queued` sessions (enqueued, not dropped),
  promoted oldest-first by `Orchestrator.promoteQueued()` as slots free.
  **`runningCount` (excludes `.queued`) is the capacity gate, NOT `active.count`** —
  counting queued sessions as occupied would deadlock the queue. `maxConcurrent` is
  now configurable (`KeychainStore.maxConcurrentSessions`, Settings stepper, default
  2, clamped ≥1). Queued sessions keep their 🍋 trigger label (skipped by
  reconcileLabels) and persist/restore.

- **#54 auto-cleanup (user choice).** A `.reviewing` session whose PR merges (primary,
  `isPRMerged`) or whose issue closes (secondary, new `IssueSourceClient.isIssueClosed`,
  GitHub-implemented, default-false elsewhere) now auto-tears-down via `cleanupSession`
  — no manual click. `prMerged` doubles as the "cleanup kicked off" guard. Chosen over
  confirm-first for the unattended Mac-mini.

- **#55 leak GC + quit policy.** Quit policy is deliberately **no-teardown** (guaranteed
  re-adopt suits long-running sessions across restarts, #35/#38). The leak is bounded by
  a startup sweep (`Orchestrator.reconcileOrphans` → `WorktreeRunner.gcStaleWorktrees`):
  prune dead+untracked lemon worktree registrations (+branch) recognized via
  `git worktree list` (by registration, not /tmp dir — the stale entry survives the
  dir), and kill un-adoptable orphan tmux while LEAVING live-matchable ones for re-adopt.
  Escape hatch: `tmux -L lemon kill-server`.

- **#51 label desync.** Root cause was reconcile precedence: `pollUntilDone` checked
  Waiting before InProgress, so a both-present set pinned status to Waiting and fed
  reconcileLabels `building=false` (a death spiral). Fix: InProgress wins when both
  present, and re-clear the stale Waiting. Both runner + orchestrator now agree
  "building wins."

- **#48 glyph decay.** `MenuBarGlyph.aggregate` gained `lastRecentEndedAt`+`now`; a
  failure colors the glyph red only within `errorWindow` (5 min), then decays to idle.

- **#57/#67 gate UI.** Both gate cards now carry a notes field (threaded through
  `resolveGate(…notes:)`, injected as text + a SEPARATE Enter on Request-changes), a
  chat composer (`Orchestrator.sendMessage`), and a Join button (#67). Footer Join is
  dropped at gates to avoid a duplicate.

- **#64 phone plan-approval.** Phone approval uses claude's native ExitPlanMode picker
  and bypasses both `resolveGate` AND the gate sentinel, so Lemon hung at `.planReview`.
  A pane-log detector in `planGatePhase` (Signal 1: edit/exec tool bullet = build began;
  Signal 2: "ask again" permission prompt = stalled in default mode) now writes the gate
  sentinel itself (idempotent release) and re-asserts auto (Shift+Tab / `BTab`) **only
  when a prompt is visible** (a blind Shift+Tab would toggle auto OFF). Detectors are
  pure + unit-tested; **the exact ExitPlanMode strings + keybinding still need real
  claude + a real phone** to confirm.

**Sandbox mock-PR seam (enabler).** The sandbox has no GitHub for `gh pr list`, so the
completion path was untestable and `make sandbox-test` was stuck at 11/13. fake-claude
now writes a PR-URL sentinel `/tmp/lemon-pr-<slug>` on "open PR"; `WorktreeRunner.detectPR`
reads it under `KeychainStore.isSandbox`. Sandbox lifecycle is now **13/13** end-to-end.
Set `LEMON_FAKE_NO_PR=1` to skip the sentinel and exercise the #53 "no PR found" bounce.

**Follow-ups (logic-verified + unit-tested, but no bespoke sandbox scenario yet):**
multi-issue queue promotion (#46), startup GC pruning (#55), and the #64 phone-approve
park-loop release. Add `LEMON_FAKE_PHONE_APPROVE` + a multi-issue scenario when tuning these.
