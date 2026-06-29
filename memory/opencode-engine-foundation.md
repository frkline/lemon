---
title: OpenCode engine foundation in workspace config
type: decision
status: active
date: 2026-06-29
issue: 92
related: [[next-session-playbook]], [[plan-gate-workflow]]
---

Issue #92 is too large to land safely as one change, so we split it into a
backward-compatible foundation first: each `Workspace` now stores an explicit
`engine` config (`claude_code` default, optional `opencode` settings).

This slice also introduces the first runtime seam: `AgentEngine` with a
`ClaudeCodeEngine` implementation, and `WorktreeRunner` now launches through the
engine interface instead of calling Claude launch wiring directly.

Settings/workspace editing now also includes **engine readiness checks** keyed by
engine kind: Claude probes `claude` + `tmux` + `gh` + `hf` + `claude whoami`, and
OpenCode probes `opencode`, auth.json, model slots, and daemon `/doc` reachability.

Runtime scaffolding for OpenCode now exists but is intentionally non-authoritative:
`OpenCodeClient` models the key REST calls (`/doc`, `/session`, message, permission)
and `OpenCodeDaemonManager` owns a minimal local daemon lifecycle seam. This is the
 substrate for the future `OpenCodeEngine` execution path; the reviewed Claude path
 remains unchanged while we incrementally swap orchestration onto structured events.

**Why:** the workspace is Lemon's execution boundary already (routing + lockdown +
filesystem mapping). Engine choice and model policy belong at that same boundary,
and storing it now lets UI and migration land before runtime orchestration changes.

**How to apply:**
- Treat `Workspace.engine.kind == .claudeCode` as the default when reading legacy
  workspaces that predate engine support.
- Keep OpenCode settings schema in `WorkspaceEngineConfig` / `OpenCodeWorkspaceConfig`
  even before runtime execution uses it, so Settings edits are durable.
- Preserve runtime behavior while extracting `AgentEngine` incrementally.
  Current behavior is unchanged (Claude still launches), but new orchestration
  should add to the engine abstraction rather than `WorktreeRunner` directly.
- Keep readiness checks engine-owned (`AgentEngine.readiness`) so UI surfaces
  don't accumulate engine-specific shell logic.
