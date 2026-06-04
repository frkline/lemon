# Lemon

A personal workflow orchestration menu-bar app for Claude Code + Linear, leveraging Gemma 4 on device. Made for the Mac mini sitting on your desk. Tag a Linear issue with 🍋 and Lemon spins up a git worktree, launches the user's own `claude` CLI in Terminal, monitors progress via Linear labels, and posts a report when the PR is ready. The intelligence is Claude Code (your login) and a small local Gemma 4 classifier — Lemon itself is glue.

## Repo layout

```
app/                 SwiftUI macOS 26 app (orchestrator + UI)
  Lemon/             Source files
    LemonApp.swift        @main — MenuBarExtra, onboarding gate, dual idle/active icons
    LemonDesign.swift     Design tokens (LD.*), button styles, StatusPill
    Models.swift          LinearIssue, Session, SessionStatus, WorkspaceRepo
    KeychainStore.swift   Secret read/write (Keychain) + non-secret config (UserDefaults)
    LinearClient.swift    GraphQL: label-based polling, label mutations, comment posting
    Orchestrator.swift    Poll loop, spawns WorktreeRunner per issue, re-trigger detection
    SessionStore.swift    Active + recent session state
    WorktreeRunner.swift  Per-session: worktree setup, Terminal launch, label polling, cleanup
    LemonLogger.swift     os.Logger subsystem constants
    Onboarding/           First-run wizard (3 steps: Linear key → Workspace → Done)
    Views/                PopoverView, SessionRowView, SessionDetailView, SettingsView
```

## Design system

All colors, animations, and button styles live in `app/Lemon/LemonDesign.swift` (`LD.*`).

- **Never** use hardcoded hex colors or `Color(..)` literals in views — use `LD.*` tokens
- `LD.lemon` (#F7C842) appears once per screen, on the primary action
- Console views use `LD.consoleBackground` (warm near-black) + `LD.consoleText`
- Animations: `LD.snappy` for interactions, `LD.smooth` for state changes, `LD.slide` for step transitions
- Button styles: `LemonButtonStyle` (primary), `GhostButtonStyle` (secondary)

## App architecture

```
LemonApp (@main)
  → shows OnboardingView if KeychainStore.shared.isConfigured == false
  → shows PopoverView once configured (MenuBarExtra .window style)
  → dual menu bar icons: MenuBarIconIdle / MenuBarIcon (active)

Orchestrator (poll loop: 15s when active, 45s when idle)
  → LinearClient.fetchLemonQueue()   → issues with 🍋 label → start session
  → LinearClient.fetchCompleteIssues() → issues with 🍋 Complete → check for human reply → re-trigger
  → WorktreeRunner.run(issue:workspace:retrigger:) per new issue (max 2 concurrent)
  → SessionStore tracks active + recent sessions

WorktreeRunner (one per Linear issue)
  → git worktree add /tmp/lemon-{identifier} -b lemon/{identifier} origin/main
  → writes LEMON_CONTEXT.md with issue details + completion checklist
  → updates Linear labels: removes 🍋, adds 🍋 In Progress
  → launches Terminal via `open -a Terminal launcher.sh`
  → polls Linear every 10s for label changes (🍋 Waiting / 🍋 Complete)
  → on 🍋 Complete: posts Lemon Report comment, cleans up worktree
  → sentinel file (/tmp/lemon-exit-{identifier}) detects early claude exit
```

## Linear label workflow

| Label | Set by | Meaning |
|-------|--------|---------|
| `🍋` | Human | Trigger — Lemon picks this up on next poll |
| `🍋 In Progress` | Lemon | Worktree active, Claude running |
| `🍋 Waiting` | Claude | Paused, needs human input |
| `🍋 Complete` | Claude | PR open, Lemon posts report and cleans up |

Re-trigger: human replies to the Lemon Report comment on a `🍋 Complete` issue → Lemon reuses the branch, re-labels `🍋 In Progress`, launches a new Claude session.

## Claude session launch command

WorktreeRunner launches Claude via a shell script opened in Terminal.app:

```bash
claude --enable-auto-mode --remote-control
```

**Both flags are required — do not drop either one:**
- `--enable-auto-mode` — runs non-interactively without confirmation prompts
- `--remote-control` — sends push notifications to the user's phone when Claude is waiting for input

## Build

```sh
# Build — warnings are errors; both must be clean before work is done
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" build

# Test — run after every change; must pass alongside a clean build
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" -destination 'platform=macOS' test

# App — open app/Lemon.xcodeproj in Xcode 26, build target "Lemon"
# Unsandboxed (direct download at lemon.living, not App Store)
```

## UI iteration loop

The app ships a self-contained smoke test that screenshots every UI state without Keychain, Linear, or a running tmux session. Claude uses this loop to explore, verify, and refine UI changes autonomously.

### Commands

```sh
make ui               # incremental build (~8s) + smoke run (~5s) — the main loop command
make smoke            # smoke only, no rebuild — fast re-run after layout/color tweaks
make watch            # fswatch auto-triggers `make ui` on every .swift save (needs: brew install fswatch)
make build-ui         # build only, to /tmp/lemon-build/Lemon.app
make test             # XCTest suite (Keychain, LinearClient, Gemma, LocalLLM, WorktreeRunner)
make integration-test # Shell tests: tmux lifecycle, mock Gemma server, claude -p read-only query
make loop             # Full validation: build-ui + test + smoke (≈30s)
```

### How the smoke test works

`--mock` seeds `Orchestrator` with two active sessions and one completed session (no Linear API calls, no Keychain access). `--smoke-test` additionally opens a plain `NSWindow` showing `PopoverView`, drives `AppNavigation` through every state, and screenshots each one via an in-process bitmap grab (no screen-recording permission needed). After the main UI states, it opens a separate `NSWindow` with `OnboardingView` and screenshots each of the 5 onboarding steps. The app then calls `NSApp.terminate(nil)` and exits.

Screenshots land in `/tmp/lemon-smoke/<timestamp>/` with a `latest` symlink pointing to the most recent run. The smoke script prints `★` next to any file whose 32×32 structural thumbnail changed from the previous run — unchanged states are silent.

### Integration test (`make integration-test`)

`scripts/integration-test.sh` exercises process-level behaviors that XCTest can't reach:

- **tmux lifecycle** (requires `brew install tmux`): session create, `pipe-pane` log growth, silence detector activation, sentinel write, `send-keys`, teardown
- **Mock Gemma server**: Python one-liner HTTP server on port 8488 returns a valid `GemmaResponse`; verifies the curl → JSON decode pipeline end-to-end
- **Claude read-only query**: runs `claude --print` against `app/Lemon/Views/` with `--allowedTools "Bash(ls*)"` (no writes), verifies `.swift` filenames appear in output
- **classify() end-to-end**: feeds Claude's output into the mock Gemma server as a `classify()` request, verifies `state` decodes correctly

tmux tests are skipped when `tmux` is not installed; Gemma + Claude tests always run (require `python3` and `claude` CLI).

### Scenarios captured

| File | State |
|------|-------|
| `01-list.png` | Main list — active + recent sessions |
| `02-detail-executing.png` | Session detail — executing, AI summary, console |
| `03-detail-waiting-pending.png` | Session detail — waiting, pending Gemma action toast |
| `04-settings.png` | Settings pane |
| `05-empty.png` | Empty state — no sessions |
| `06-onboarding-linear.png` | Onboarding step 1 — Linear API key |
| `07-onboarding-workspace.png` | Onboarding step 2 — Workspace repos |
| `08-onboarding-lemonmd.png` | Onboarding step 3 — LEMON_CONTEXT.md preview |
| `09-onboarding-localai.png` | Onboarding step 4 — Local AI (Gemma) setup |
| `10-onboarding-ready.png` | Onboarding step 5 — Ready / finish |

### Mock and test flags

| Flag | Effect |
|------|--------|
| `--mock` | `isConfigured → true`, skips Keychain reads, seeds mock sessions, no polling |
| `--smoke-test` | Opens smoke window, drives nav, screenshots, exits |
| *(XCTest env)* | `XCTestConfigurationFilePath` detected → `isConfigured → false`, suppresses Keychain dialog |

### Adding a new scenario

1. Add a new step to `SmokeTestDriver.run()` in `app/Lemon/SmokeTestDriver.swift` — mutate `nav` or `orchestrator.sessions` directly, call `await shot("06-my-state")`.
2. If the scenario needs specific mock data, add it to `Orchestrator.seedMockSessions()` in `Orchestrator.swift`.
3. Run `make ui` and read the new screenshot.

### Claude's iteration pattern

```
1. make ui                     — build + smoke (~6–13s total)
2. SendUserFile on every .png in /tmp/lemon-smoke/latest/
   → surfaces screenshots directly in the conversation
3. read each image, note ★-marked changes
4. identify the issue          — wrong color, clipped text, missing state, etc.
5. edit the relevant .swift    — view, design token, or mock data
6. goto 1
```

Always send **all ten** screenshots after each `make ui`, not just the ★-changed ones — context from adjacent states matters for design decisions.

`make smoke` (no rebuild) is useful when only adjusting spacing, colors, or mock copy — Swift re-compilation is skipped, the existing binary re-runs in ~5s.

### Screenshot delivery (step 2 expanded)

After every smoke run, send the files with `SendUserFile`:

```
files: [
  "/tmp/lemon-smoke/latest/01-list.png",
  "/tmp/lemon-smoke/latest/02-detail-executing.png",
  "/tmp/lemon-smoke/latest/03-detail-waiting-pending.png",
  "/tmp/lemon-smoke/latest/04-settings.png",
  "/tmp/lemon-smoke/latest/05-empty.png",
  "/tmp/lemon-smoke/latest/06-onboarding-linear.png",
  "/tmp/lemon-smoke/latest/07-onboarding-workspace.png",
  "/tmp/lemon-smoke/latest/08-onboarding-lemonmd.png",
  "/tmp/lemon-smoke/latest/09-onboarding-localai.png",
  "/tmp/lemon-smoke/latest/10-onboarding-ready.png"
]
status: normal
```

This keeps the design feedback loop fully in the conversation — no Finder, no Preview.app, no manual file inspection.

## Secrets and config

Only the Linear API key is sensitive — it lives in Keychain. Everything else is UserDefaults.

| Value | Storage | Key |
|-------|---------|-----|
| Linear API key | Keychain | `lemon-linear-key` |
| Linear user ID | UserDefaults | `lemon-linear-user-id` |
| Workspace config (JSON) | UserDefaults | `lemon-workspace-config` |

`KeychainStore.swift` handles all reads and writes. **Never** read secrets from files or environment variables on the host.

Workspace config is a JSON array of `WorkspaceRepo` objects:
```json
[{"path": "/Users/frank/Projects/myapp", "issuePrefix": "LEM", "homeRepo": "", "allReposInFolder": false}]
```

## Rules

- **Never** `git add -A` or `git add .` — stage explicit paths
- **Never** store secrets anywhere except Keychain
- All subprocesses must `cd /tmp` first (or use an explicit working directory) — launching from the home directory triggers macOS permission popups for Music, Contacts, etc.
- macOS 26 only
