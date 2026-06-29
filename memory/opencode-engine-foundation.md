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
OpenCode probes `opencode`, auth.json, model slots, provider-key coverage for the
selected models, and daemon reachability against the real OpenCode HTTP surface.

Runtime scaffolding for OpenCode now has a first execution path: `OpenCodeEngine`
ensures the daemon, creates a session via `/session`, and sends the kickoff
message via `/session/:id/message`.

`WorktreeRunner` now treats OpenCode as **non-tmux monitored** runtime: no tmux
liveness checks, no pane-log Gemma classify loop, and no plan-gate sentinel wait.
It still uses the shared issue-label polling + completion handler path so Lemon's
source-side lifecycle stays consistent while OpenCode event integration is pending.

Follow-on hardening:
- OpenCode sessions persist their OpenCode `session.id` to `/tmp/lemon-opencode-session-{slug}`.
- Polling now checks both daemon `/doc` reachability and session liveness (`/session/:id`);
  terminal/not-found responses fail the run instead of lingering in a hung `.executing` state.
- Gate/chat controls in `Orchestrator` now branch by engine kind: Claude keeps tmux
  send-keys, while OpenCode routes free-form text (including gate change notes) via
  daemon `sendMessage` when a session id is available.
- Model IDs now parse provider slugs (`provider/model`) and readiness performs a
  provider-specific auth check against `~/.local/share/opencode/auth.json` for the
  exact providers referenced by plan/code/review slots. Launch also fails early if
  selected providers are clearly missing credentials.
- Workspace model dropdowns now merge static fallbacks + saved selections +
  **daemon-discovered models** by querying OpenCode (`/config/providers`, `/provider`,
  `/api/model`, then `/doc` as fallback) and extracting likely `provider/model` IDs.
  This keeps the UI aligned with whichever model catalog the local OpenCode daemon
  currently exposes.
- OpenCode config is global-first: `KeychainStore.openCodeDefaults` stores the
  default daemon, model slots, and auto-open threshold. Workspaces inherit those
  defaults when `Workspace.engine.openCode == nil` and only persist an override
  when their OpenCode settings differ. This matches OpenCode's user-global auth and
  provider catalog; most people pick one provider/model policy for the Mac, not one
  per repo.
- `OpenCodeClient` follows the OpenCode 1.17 HTTP contract: session creation passes
  `directory` as a query item and `model` as `{providerID,id}`; messages send text
  parts instead of the older flat `content` shape. OpenCode response bodies are not
  logged because provider/catalog responses can contain auth material.

**Why:** the workspace is Lemon's execution boundary already (routing + lockdown +
filesystem mapping). Engine choice and model policy belong at that same boundary,
and storing it now lets UI and migration land before runtime orchestration changes.

**How to apply:**
- Treat `Workspace.engine.kind == .claudeCode` as the default when reading legacy
  workspaces that predate engine support.
- Keep OpenCode settings schema in `WorkspaceEngineConfig` / `OpenCodeWorkspaceConfig`
  even before runtime execution uses it, so Settings edits are durable.
- Treat `Workspace.engine.openCode == nil` as "use global OpenCode defaults," not
  as "use hardcoded empty OpenCode config." All OpenCode runtime/client lookups must
  resolve through `KeychainStore.openCodeDefaults` before falling back to literals.
- Keep Claude path unchanged; add OpenCode behavior only behind
  `Workspace.engine.kind == .openCode`.
- OpenCode launch is daemon/API-driven (not tmux). Any restore/reattach logic
  that assumes tmux liveness must branch by engine kind.
- Keep readiness checks engine-owned (`AgentEngine.readiness`) so UI surfaces
  don't accumulate engine-specific shell logic.
