# LEMON.md

## What this is

Lemon is a personal **menu-bar macOS app** that orchestrates Claude Code sessions driven by Linear or GitHub Issues labels. The user tags an issue with `🍋`; Lemon spins up a git worktree, launches `claude` in Terminal, and uses a local **Gemma 4** classifier (via SwiftLM + MLX) to auto-handle routine prompts so only the questions that need a human reach the user. Built for one developer on Apple Silicon (macOS 26 / Xcode 26); Lemon itself is glue — the intelligence is Claude Code.

## The workflow (plan-gate, issue #11)

A 🍋 issue runs as **one `claude` session with two human gates**:

1. **Plan gate.** Fresh sessions launch `--permission-mode plan`. The kickoff first asks Claude to **triage** (clear? not a dup? unblocked?) — if not, Claude posts a clarifying comment, sets 🍋 Waiting, and stops (`planGatePhase` detects the 🍋 Waiting and pauses as `.waiting`). Otherwise Claude proposes a plan via ExitPlanMode; an `ExitPlanMode` hook (`.claude/settings.json`, written per-worktree) copies the plan to `/tmp/lemon-plan-{slug}.md`. `WorktreeRunner.planGatePhase` posts the plan to the issue (🍋 Waiting, `.planReview`) and parks. The user approves in the popover / via `approve_gate` MCP / remote control → `Orchestrator.resolveGate` send-keys **"1"** ("Yes, and use auto mode") + writes `/tmp/lemon-gate-{slug}`, and the **same session** continues into the build. **Request changes** sends "4" + a `changes` sentinel → Claude re-plans. **Autopilot opt-out:** a `🍋 auto` label on the issue skips the plan gate (straight to auto) for trivial work.
2. **Result gate (opt-in).** When the build writes `/tmp/lemon-result-{slug}.md` instead of opening the PR, Lemon parks at `.resultReview` until approval, then the session opens the PR. Absent that sentinel, the 🍋 Complete → report → cleanup path runs unchanged (retriggers, autopilot).

The menu-bar glyph reflects aggregate state: idle / working / waiting (a gate or mid-build question) / done / error (`MenuLemon*` template assets, `MenuBarGlyph.aggregate`).

## Key directories

- `app/Lemon/` — SwiftUI sources. Entry: `LemonApp.swift`. Core: `Orchestrator.swift` (poll loop), `WorktreeRunner.swift` (per-session lifecycle), `LocalLLM.swift` (Gemma classifier), `LinearClient.swift` / `GitHubClient.swift` (both conform to `IssueSourceClient`), `LemonDesign.swift` (LD.* tokens), `LemonMCPServer.swift` (recursive-mode MCP surface).
- `app/Lemon/Views/` — `PopoverView`, `SessionRowView`, `SessionDetailView`, `SettingsView`.
- `app/Lemon/Onboarding/` — first-run wizard.
- `app/LemonTests/` — XCTest suite.
- `scripts/` — `smoke-test.sh` (UI screenshots), `integration-test.sh` (tmux + mock Gemma).
- `docs/` — `index.html` for lemon.living + `img/`.

## Dev loop, build, test

```sh
make ui                # build (~8s) + smoke screenshots → /tmp/lemon-smoke/latest/
make watch             # fswatch-driven auto rebuild
make test              # XCTest
make integration-test  # tmux lifecycle + mock Gemma + claude -p
make loop              # build-ui + test + smoke
```

Builds go to `/tmp/lemon-build/Lemon.app`. **`-warnings-as-errors` is enforced** — both build and tests must be clean.

### Workflow sandbox — iterate on orchestration with no tokens / no side effects

The killer dev loop for the workflow itself. A file-backed tracker (`MockIssueClient`, `LEMON_SANDBOX=1`) + a scripted `claude` stand-in (`fake-claude.sh`, `LEMON_CLAUDE_BIN`) run the **entire** plan→gate→build→gate→PR lifecycle against `/tmp/lemon-sandbox` fixtures — no GitHub/Linear calls, no Claude tokens, no public side effects.

```sh
make sandbox-init                    # throwaway git workspace + fixtures
make sandbox-issue T="Add X"         # file a 🍋 fixture issue
make sandbox                         # relaunch Lemon in sandbox mode (fake-claude + MCP)
make sandbox-test                    # drive one issue end-to-end WITH ASSERTIONS (8/8)
make sandbox-show                    # inspect fixture labels + comments
```

`scripts/sandbox-scenario.sh` asserts the two-gate lifecycle; `scripts/sandbox-retrigger.sh` exercises re-trigger. To truth-check against **real** claude, launch `LEMON_SANDBOX=1` *without* `LEMON_CLAUDE_BIN`. See CLAUDE.md → "Workflow sandbox" for the full map.

## Deployment & branches

- Distribution: signed `.app` via **GitHub Releases** ([github.com/frkline/lemon/releases](https://github.com/frkline/lemon/releases)) — direct download, *unsandboxed*, not App Store.
- Lemon's own worktrees: `lemon/{slug}` branches cut from `origin/main` at `/tmp/lemon-{pathSlug}`.

## Conventions & constraints

- **Never** hardcode hex colors or `Color(...)` in Views — use `LD.*` tokens. `LD.lemon` (#F7C842) appears once per screen.
- The Claude launch line: fresh sessions use `--permission-mode plan` (the plan gate), retriggers use `--permission-mode auto`; both keep `--remote-control` and the `--` separator (load-bearing — `--remote-control`'s optional name arg eats the kickoff prompt without `--`). The binary is `"${LEMON_CLAUDE_BIN:-claude}"` so the sandbox can inject `fake-claude`.
- `IssueRef.pathSlug` drives all paths/tmux names; **don't** use `identifier.lowercased()` (GitHub IDs contain `/` and `#`). `IssueRef.trackingKey` namespaces by source (`linear:` / `github:`).
- Workspace config = `WorkspacePair` (source + workspace), capped at 10, stored in `lemon-workspace-pairs`. Secrets in Keychain, never on disk.
- Unattended runs: `LEMON_LINEAR_KEY=...` (inline beats `_FILE`) + `LEMON_ENABLE_MCP=1` + direct exec of `Lemon.app/Contents/MacOS/Lemon`. MCP enable also needs `defaults write rocks.harpy.lemon lemon-mcp-enabled -bool true` (known wart). MCP binds **127.0.0.1 only, no auth**.
- See `CLAUDE.md` for the full architecture and known gaps.