---
title: Always-on labeler-trust (belt-and-suspenders trigger)
type: decision
status: active
date: 2026-06-28
related: [[next-session-playbook]], [[sandbox-iteration-loop]], [[plan-gate-workflow]]
---

A GitHub trigger requires **two independent "this is me" signals, always**:
the issue is **assigned to you** AND **you applied the 🍋**. Either alone is
insufficient. The 🍋-labeler check (`triggerLabelActor`, the events-API lookup
from #13 M2) is **no longer gated by `workspace.lockdown`** — it runs on every
poll. `lockdown` is left governing only the stricter extras: M3
(trusted-commenter re-trigger) and M4 (untrusted-content drop-vs-wrap).

Source split:
- **GitHub** exposes the labeler via the issue events API → authoritative. The
  labeler must equal you (`TrustPolicy.isTrusted`), composed with the assignee
  scope already enforced by `GitHubClient.fetchTriggerQueue`'s `assignee:LOGIN`
  search.
- **Linear** can't cheaply query the labeler (`triggerLabelActor` → `nil`) →
  **fail-open**: the `assignee`/`userId` queue stays the gate. The author-trust
  fallback (`isKnownOutsider`) is kept but only under `lockdown`, as a
  lockdown-only stricter extra for labeler-undeterminable sources.

**Why:** before this, outside lockdown a teammate or bot could apply 🍋 to an
issue assigned to you and it would trigger — only one signal. Nobody should be
able to kick off an auto-mode Claude session you didn't intend. This supersedes
the earlier "labeler *instead of* assignee" framing — it's additive (both
required), not a replacement.

**How to apply:** the gate lives in `Orchestrator.pollWorkspace`'s trigger loop
(`if let labeler { require isTrusted } else if lockdown { author fallback }`).
The sandbox models it: `SandboxIssueFixture` has `author`/`labeledBy`/`assignee`;
`MockIssueClient.fetchTriggerQueue` filters `assignee == handle` and
`triggerLabelActor` returns `labeledBy`. `scripts/sandbox-lockdown.sh` Part A
(lockdown OFF) proves the gate stands alone; M4 body-wrapping is still exercised
by triggering an **outsider-authored, you-labeled** issue (you authorized it →
the outsider body is delimited). Shipped in #31.
