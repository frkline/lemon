---
title: Workflow sandbox / autonomous iteration loop
type: decision
status: active
date: 2026-06-27
related: [[plan-gate-workflow]], [[claude-code-plan-mode]]
---

To tune the plan-gate workflow meticulously (and for free / side-effect-free), build a
sandbox that exploits Lemon's two existing protocol seams plus its mock infrastructure. The
principle: **separate the expensive/irreversible parts (real GitHub, real `claude` tokens)
from the logic we iterate on (orchestration state machine + Gemma prompts).**

**Landed 2026-06-27 (build + tests green):** components 1, 3, the harness/Make targets,
AND the asserting scenario runner (part of 2). `make sandbox-test`
(`scripts/sandbox-scenario.sh`) drives one issue end-to-end and asserts session-created ·
In Progress · Complete · Lemon Report · MCP Reviewing, with a real exit code. It already
earned its keep — caught a stale-worktree bug and an app-kill/MCP-port race on first run.
Files: `app/Lemon/MockIssueClient.swift`, `scripts/sandbox.sh`, `scripts/fake-claude.sh`,
`scripts/sandbox-scenario.sh`, `make sandbox*` targets, CLAUDE.md "Workflow sandbox".
Seams: `LEMON_SANDBOX=1` (KeychainStore + Orchestrator.client(for:)), `LEMON_CLAUDE_BIN`
(WorktreeRunner launcher). **Still TODO:** `approve_gate` MCP tool (rest of 2 — needed once
the gates exist), 4 (Gemma corpus), 5 (gate smoke states). 6 (real-claude-against-fixtures)
is already usable: omit LEMON_CLAUDE_BIN.

Components (build order = priority):

1. **`MockIssueClient`** — conforms to `IssueSourceClient`, reads/writes issues+labels+
   comments as JSON fixtures under `/tmp/lemon-sandbox/`. Returned by
   `Orchestrator.client(for:)` when `LEMON_SANDBOX=1`. Dropping a fixture = triggering a
   test issue; label flips + Lemon's comments write back to inspectable files. Keystone —
   decouples the whole workflow from GitHub/Linear. Works against today's flow too.
2. **`approve_gate` MCP tool + scenario runner** (`make workflow`) — the popover "Approve
   & run" backend, exposed via MCP so a script can answer gates. Runner = build → relaunch
   unattended in sandbox → drop issue → drive via MCP → assert fixture state.
3. **`fake-claude.sh`** — mimics claude's observable surface (scripted pane output, writes
   the plan file + ExitPlanMode hook sentinel, parks for `send-keys "1"`, then "implements",
   signals done; plus a misbehave mode). Selected via env override of the claude binary in
   the launcher. Makes the loop free + deterministic; solves the ~2× session-limit cost.
4. **Gemma golden corpus** — captured pane snapshots per picker shape (plan-approval,
   Bash perm, edit, MCP, git push, ambiguous) + expected `classify()` verdicts; a harness
   diffs real Gemma output vs expected. Seed from the spike's real plan-picker text. This
   is how to tune `LocalLLM.classify()` prompts without regressions.
5. **Gate smoke states** — add `.planReview` / `.resultReview` scenarios to
   `SmokeTestDriver` to see + screenshot the gate UI with mock data.
6. **Real-claude-against-fixtures mode** (`LEMON_SANDBOX_REAL_CLAUDE=1`) — same fixture
   workspace, real CLI, opt-in, for periodic truth-checks of orchestration assumptions.

**Scenarios + verification patterns that have paid off:**
- `make sandbox-test` (`sandbox-scenario.sh`) — asserts the two-gate lifecycle (8/8).
- `sandbox-retrigger.sh` — validates #9 end-to-end (reply re-triggers once → 2nd report
  advances the marker → relaunch does NOT re-fire). Gotcha: it must `rm` the
  `.reviewing` worktree before relaunch (the real flow's "Cleanup worktree" step) or the
  leftover blocks the re-trigger's `git worktree add`.
- **Unit-test the tracker layer to isolate sandbox failures.** When a sandbox scenario
  missed re-trigger, `MockIssueClientTests` proved detection (findLemonMarker +
  hasNewComment) was correct — so the miss was orchestration/worktree, not the marker
  logic. Watch out: `MockIssueClient.loadAll()` reads ALL fixtures in the shared dir, so
  select your issue by identifier, not `.first`.
- **Menu-bar glyph can't be smoke-screenshotted** (it's the system `MenuBarExtra`, not the
  popover). Verify via a white-on-dark SVG montage (`qlmanage -t` rasterizes SVG incl.
  masks — no brew rasterizer needed) + unit tests of `MenuBarGlyph.aggregate`.

**Why:** the workflow involves real `claude` sessions + tracker mutations; iterating
against those is slow, costly (Max limits), and has side effects on a public repo.
**How to apply:** build the sandbox FIRST, then implement plan-gate Phase 1 inside it.
Reuse: `isMockMode`/`MockAppState`, `integration-test.sh` mock Gemma, MCP tools, the
unattended env-launch loop, and the `make ui`/smoke harness. See [[plan-gate-workflow]].
