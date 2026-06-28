# Lemon Memory — local knowledge graph

This directory is the project's **shared, version-controlled knowledge graph** of
agentic decisions and instructions. It is checked into the repo, so every agent and
every collaborator reads the same set of facts. It is the durable record of *why*
things are the way they are and *how* we've decided to work — the context that isn't
recoverable from code or git history alone.

Distinct from two neighbours (see `CLAUDE.md` → "Memory surfaces"):
- **`CLAUDE.md` Rules** — hard, static invariants (never `git add -A`, `cd /tmp`
  first, secrets only in Keychain). Those stay in `CLAUDE.md`.
- **`LEMON.md`** — team instructions Lemon injects into the worktrees it spawns.
- This `memory/` — **evolving decisions and rationale** that grow over time.

## Node format

One fact per file, kebab-case name (`plan-gate-workflow.md`). Frontmatter:

```markdown
---
title: Short human title
type: decision | instruction | constraint | reference
status: active | superseded | proposed
date: YYYY-MM-DD
related: [[other-node]], [[another-node]]
---

The fact, stated plainly.

**Why:** the rationale — the part that isn't obvious from the code.
**How to apply:** what an agent should do with this.
```

## Edges

Link related nodes inline with `[[node-name]]` (the filename without `.md`). The
links are the graph's edges — link liberally; a `[[node]]` that doesn't exist yet is
a valid "this is worth writing" marker, not an error.

## How agents use it

- **Before deciding** something architectural or process-related, skim the index
  below and read any related node — don't re-litigate a settled decision.
- **After deciding**, add or update a node and add one line to the index. Prefer
  updating an existing node over creating a near-duplicate. When a decision is
  reversed, set the old node's `status: superseded` and link the replacement.

## Index

- [plan-gate-workflow](plan-gate-workflow.md) — *decision* — target 🍋 flow: plan-first,
  two human gates, single session that switches mode at the approval picker. Phase 0
  spike done; not yet built. Spec in `WORKFLOW_DESIGN.md`.
- [claude-code-plan-mode](claude-code-plan-mode.md) — *reference* — empirical facts about
  `claude --permission-mode plan` (hooks fire, read-only, `planFilePath`, picker shape,
  folder-trust, ~2× cost) from the Phase 0 spike.
- [sandbox-iteration-loop](sandbox-iteration-loop.md) — *decision* — how to build a
  free/side-effect-free loop to tune the workflow: MockIssueClient, fake-claude, Gemma
  golden corpus, scenario runner. Build before plan-gate Phase 1.
- [next-session-playbook](next-session-playbook.md) — *project* — how to refine/bug-fix
  the workflow on a real issue: validation ladder (sandbox → real claude → real issue),
  what to look for (#31 labeler-trust, request-changes, silence stall), what's
  deliberately not done, and the issues this branch closes.
