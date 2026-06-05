# LEMON.md

## What this is

Lemon is a personal **menu-bar macOS app** that orchestrates Claude Code sessions driven by Linear or GitHub Issues labels. The user tags an issue with `🍋`; Lemon spins up a git worktree, launches `claude --permission-mode auto --remote-control` in Terminal, and uses a local **Gemma 4** classifier (via SwiftLM + MLX) to auto-handle routine prompts so only the questions that need a human reach the user. Built for one developer on Apple Silicon (macOS 26 / Xcode 26); Lemon itself is glue — the intelligence is Claude Code.

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

## Deployment & branches

- Distribution: signed `.app` via **GitHub Releases** ([github.com/frkline/lemon/releases](https://github.com/frkline/lemon/releases)) — direct download, *unsandboxed*, not App Store.
- Lemon's own worktrees: `lemon/{slug}` branches cut from `origin/main` at `/tmp/lemon-{pathSlug}`.

## Conventions & constraints

- **Never** hardcode hex colors or `Color(...)` in Views — use `LD.*` tokens. `LD.lemon` (#F7C842) appears once per screen.
- The Claude launch line has three load-bearing pieces — `--permission-mode auto`, `--remote-control`, and the `--` separator. Don't drop any.
- `IssueRef.pathSlug` drives all paths/tmux names; **don't** use `identifier.lowercased()` (GitHub IDs contain `/` and `#`). `IssueRef.trackingKey` namespaces by source (`linear:` / `github:`).
- Workspace config = `WorkspacePair` (source + workspace), capped at 10, stored in `lemon-workspace-pairs`. Secrets in Keychain, never on disk.
- Unattended runs: `LEMON_LINEAR_KEY=...` (inline beats `_FILE`) + `LEMON_ENABLE_MCP=1` + direct exec of `Lemon.app/Contents/MacOS/Lemon`. MCP enable also needs `defaults write rocks.harpy.lemon lemon-mcp-enabled -bool true` (known wart). MCP binds **127.0.0.1 only, no auth**.
- See `CLAUDE.md` for the full architecture and known gaps.