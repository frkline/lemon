---
title: Next-session playbook — refine the plan-gate workflow on a real issue
type: project
status: active
date: 2026-06-28
related: [[plan-gate-workflow]], [[sandbox-iteration-loop]], [[claude-code-plan-mode]]
---

The plan-gate workflow (two gates, lockdown, menu glyph, real-claude-validated) is
implemented and about to merge. The next phase is **refinement + bug-fixing against a
real issue**, not greenfield. Here's how to work and what to watch.

## How to validate (cheapest → realest)
- **Fast, free, deterministic:** `make sandbox-test` (two-gate, 8/8), `scripts/sandbox-request-changes.sh` (re-plan loop), `scripts/sandbox-lockdown.sh` (trust/M2/M4). Edit orchestration → re-run → green or a precise failure. These run with `LEMON_SANDBOX=1` + `fake-claude` (no GitHub, no tokens).
- **Real claude, fixtures:** launch `LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1` **without** `LEMON_CLAUDE_BIN` → real `claude` against the throwaway repo. Pre-trust now skips the folder-trust prompt. Drive/observe via MCP: `force_classify` (real Gemma verdict), `force_classify {act:true}` (classify + send keys), `get_pane_log`, `approve_gate`, `send_keys`.
- **Real issue:** a 🍋 on `frkline/lemon` itself. Watch a real plan gate form, approve from the popover/phone, and a real PR open.

## What to look for (likely refinement areas)
1. **#31 — labeler-trust as the core trigger model.** The headline refinement. Today the GitHub queue is `assignee:LOGIN` and lockdown layers labeler-trust on top, so the effective rule is *assigned-to-you AND 🍋 AND labeled-by-you*. Moving to `label:🍋` + always-on `triggerLabelActor` is more intuitive and closes the public-repo surface universally. The sandbox doesn't model the assignee filter — add an `assignee` fixture dimension when doing this.
2. **Real-claude request-changes** — validated with `fake-claude`; not yet end-to-end with real claude. Run it once on a real plan gate.
3. **Silence-timer stall** for prompts other than folder-trust (which is now pre-trusted). Real claude may hit a mid-session prompt; today Gemma only auto-acts after the silence window. Consider a faster first-classify or wiring `force_classify act` into the runner.
4. **Result gate with real claude** — the `.lemon-result-{slug}.md` sentinel path is fake-claude-only so far; confirm real claude's completion checklist writes it (or adjust `LEMON_CONTEXT.md`).
5. **Re-trigger marker advancement (#9)** under real PRs — the fix is validated in the sandbox; confirm the marker (which carries `pr:`) parses with a real PR number.

## Deliberately NOT done (don't re-add without reason)
- The **confirm-screen phase** (#11) — dropped as friction; the plan gate already gates work. A "target branch" line on the plan card is the only piece worth considering.
- **M2 via Linear issue-history** and **network isolation** — Linear is closed/trusted (lockdown defaults off); network egress → containers (#15).

## Open issues this branch touches
- Closes on merge: #8 (classify cache), #9 (re-trigger marker), #11 (plan-gate), #26 (README). #13 already closed.
- Live follow-ups: **#31** (labeler-trust core model), #15 (containers / no-network), #4 (webhooks + sig verification).

## Ground rules (unchanged)
`-warnings-as-errors`; build + XCTest green before done. Never `git add -A`. Secrets only in Keychain. Branch off main; commit/push only when asked. Use the [[sandbox-iteration-loop]] before touching real claude.
