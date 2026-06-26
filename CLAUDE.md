# Lemon

A personal workflow orchestration menu-bar app for Claude Code + your issue tracker (Linear or GitHub), leveraging Gemma 4 on device. Made for the Mac mini sitting on your desk. Tag an issue with 🍋 and Lemon spins up a git worktree, launches the user's own `claude` CLI in Terminal, monitors progress via labels, and posts a report when the PR is ready. The intelligence is Claude Code (your login) and a small local Gemma 4 classifier — Lemon itself is glue.

## Repo layout

```
app/                 SwiftUI macOS 26 app (orchestrator + UI)
  Lemon/             Source files
    LemonApp.swift        @main — MenuBarExtra, onboarding gate, dual idle/active icons
    LemonDesign.swift     Design tokens (LD.*), button styles, StatusPill
    Models.swift          IssueRef, Session, SessionStatus, IssueSource/Scope,
                          SourceConfig, WorkspaceMapping, WorkspacePair, LemonState,
                          IssueComment + legacy LinearIssue/WorkspaceRepo
    KeychainStore.swift   Keychain secrets + UserDefaults config + pair-based workspace +
                          legacy lemon-workspace-config → pairs migration
    IssueSourceClient.swift  Protocol both LinearClient + GitHubClient conform to;
                             SourceAuth, CredentialIdentity, IssueSourceError
    LemonMarkerExtractor.swift  Shared parse/find/hasNew/bodiesAfter against [IssueComment]
    LinearClient.swift    Linear GraphQL surface + IssueSourceClient conformance
    GitHubClient.swift    GitHub REST v3 + PAT auth + IssueSourceClient conformance
    Orchestrator.swift    Poll loop: iterates keychain.pairs sequentially per-source,
                          memoizes bootstrap per pair, spawns WorktreeRunner per issue
    SessionStore.swift    Active + recent session state; isTracking by IssueRef.trackingKey
    WorktreeRunner.swift  Per-session: worktree setup, Terminal launch, label polling
                          via IssueSourceClient, cleanup. Paths/tmux keyed on pathSlug
    LemonLogger.swift     os.Logger subsystem constants
    LemonMCPServer.swift  / LemonMCPTools.swift  MCP tool surface (source-agnostic)
    Onboarding/           First-run wizard — currently Linear-first; GitHub added in
                          Settings post-onboarding (migration handles single-pair case)
    Views/                PopoverView, SessionRowView, SessionDetailView, SettingsView
                          (Settings has Linear key + GitHub PAT + pair editor)
```

### Multi-source architecture (issues #2 + #10)

- **`IssueSourceClient` protocol** — `fetchTriggerQueue`, `fetchCompleteQueue`, `fetchIssueLabels`, `applyState/clearState(LemonState)`, `postComment`, `fetchComments`, `hasNewComment`, `fetchCommentsAfter`, `findLemonMarker`, `bootstrapLabels`, `verifyCredential`. Each client maps `LemonState` to its source-specific representation internally (Linear label ID vs GitHub label name).
- **`SourceAuth`** enum — `.linear(apiKey, userId)` or `.github(pat, login)`. Built per-pair by `KeychainStore.authFor(pair:)`.
- **`WorkspacePair { source: SourceConfig, workspace: WorkspaceMapping }`** is the unit of config. Capped at 10 (`KeychainStore.maxPairs`). Stored under `lemon-workspace-pairs` JSON; legacy `lemon-workspace-config` migrates to one Linear pair per legacy `WorkspaceRepo` on first read of `keychain.pairs`, gated by the `lemon-workspace-config-migrated-at` sentinel.
- **`IssueRef.pathSlug`** drives `/tmp/lemon-{slug}` worktree paths, tmux session names, log paths, sentinels, MCP config paths. Linear: `lem-42`. GitHub: `owner-repo-7` (slashes flatten). Do NOT use `identifier.lowercased()` for paths — GitHub identifiers contain `/` and `#`.
- **`IssueRef.trackingKey`** is `"linear:<id>"` or `"github:<id>"` — used in `SessionStore.isTracking(ref:)` to keep node IDs and `owner/repo#n` disjoint.
- **Lemon Report marker** stays the same shape across sources; gains an optional `source: github` line on GitHub-origin reports. `LemonMarkerExtractor.parse` reads it back as `IssueSource?`; nil parses as legacy / Linear.

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
  → iterates keychain.pairs sequentially (per-source clients, memoized)
  → per pair: client.fetchTriggerQueue() → start session
              client.fetchCompleteQueue() → check for human reply → re-trigger
  → bootstrapLabels per-pair, memoized by pair.id (retried next poll on failure)
  → WorktreeRunner.run(ref:, pair:, client:, auth:, retrigger:) per issue (max 2 concurrent)
  → SessionStore tracks active + recent; isTracking by IssueRef.trackingKey

WorktreeRunner (one per issue)
  → git worktree add /tmp/lemon-{ref.pathSlug} -b lemon/{slug} origin/main
  → writes LEMON_CONTEXT.md with issue details + completion checklist
  → state transitions via client.applyState/clearState(LemonState)
  → launches Terminal via `open -a Terminal launcher.sh`
  → polls every 10s via client.fetchIssueLabels for state changes
  → on 🍋 Complete: posts Lemon Report comment, cleans up worktree
  → sentinel file (/tmp/lemon-exit-{slug}) detects early claude exit
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
claude --permission-mode auto --remote-control -- '<kickoff prompt>'
```

**All three pieces matter — do not drop any:**
- `--permission-mode auto` — Claude's classifier decides per-prompt: routine tool use (Bash inside the worktree, file edits, gh/git commands) is auto-accepted; destructive or ambiguous calls still prompt. This is the right balance for Lemon's `/tmp/lemon-{id}` worktree, which has internet access. Use `bypassPermissions` only if you specifically want zero prompts ever (riskier). (Earlier docs called this `--enable-auto-mode`; that flag does not exist — the real surface is `--permission-mode <auto|bypassPermissions|acceptEdits|...>` per `claude --help`.)
- `--remote-control` — sends push notifications to the user's phone when Claude is waiting for input.
- `--` separator before the trailing kickoff prompt. Without it, `--remote-control` (whose `[name]` argument is optional) eats the prompt as its session name and Claude opens an empty REPL.

## Running Lemon unattended (for iteration loops)

When Claude is driving Lemon to test changes, you want to skip the GUI Keychain prompt and have the MCP server on at launch. Two env vars do this:

```sh
LEMON_LINEAR_KEY=$(cat path/to/linear/key) LEMON_ENABLE_MCP=1 \
  /tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon &
```

- `LEMON_LINEAR_KEY` (inline value) wins over `LEMON_LINEAR_KEY_FILE` (path on disk). Inline avoids the `~/Desktop` TCC prompt that fires every launch when the file lives there. Either way `KeychainStore.envKeyBypass()` short-circuits the Keychain read.
- `LEMON_ENABLE_MCP=1` boots the MCP server on `127.0.0.1:8765` so a recursive Claude can `force_classify` / `send_keys` / `get_pane_log`. Known wart: the env-var-alone path doesn't always fire (see Known gaps); pair with `defaults write rocks.harpy.lemon lemon-mcp-enabled -bool true` if it doesn't bind.
- Direct exec (`Lemon.app/Contents/MacOS/Lemon &`) propagates env vars more reliably than `open Lemon.app` on macOS 26.

The build → kill → relaunch loop:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CONFIGURATION_BUILD_DIR=/tmp/lemon-build \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" build
pkill -f 'Lemon.app/Contents/MacOS/Lemon'; sleep 2
LEMON_LINEAR_KEY=$(cat path) LEMON_ENABLE_MCP=1 \
  /tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon &
```

## Iterating on autonomous behavior

When a session wedges in a way Gemma *should* handle but doesn't, the fix is almost always one of:

1. **Add an example to the Gemma classify system prompt** in `LocalLLM.swift:classify(...)`. The prompt has worked examples for the MCP picker, Bash perm picker (1./2./3.), git push perm, file edit confirmation, and Linear MCP tool-use perm. New picker shapes go here. Keep `summary` and `notify_user.message` under 80 chars — token budget is 300 and truncated JSON fails to parse.
2. **Fix the silence-detector input** in `WorktreeRunner.pollUntilDone(...)` — line count, not byte count; ANSI cursor redraws don't add newlines, so byte deltas lie.
3. **Adjust `LEMON_CONTEXT.md`** in `WorktreeRunner.writeContext(...)` so Claude has the context to self-handle instead of asking.

Watching what Gemma is doing in real time:

```sh
# Verdicts as SwiftLM emits them:
grep "srv  generate" /tmp/lemon-swiftlm.log | tail -10 \
  | sed 's/srv  generate: id 0 | //'

# Per-session classify timing + summary from Lemon's os.Logger:
log show --predicate 'subsystem == "com.lemon.app"' --last 5m --info \
  | grep -E 'gemma|Retrigger|Poll'
```

When Lemon's MCP is up, the same questions go via the protocol:

```sh
# Read-only: what does Gemma think right now?
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"force_classify","arguments":{"id":"HRP-37"}}}'
```

`force_classify`, `get_pane_log`, `get_session`, `list_sessions`, `get_swiftlm_log` are all read-shaped tools fit for the observe-only diagnostic role.

## Known gaps (deferred — don't re-discover)

- **MCP enable env var, alone, can miss its window.** `LEMON_ENABLE_MCP=1` is read inside the `@State` initializer's `Task { @MainActor in ... }` block in `LemonApp.swift`. In some launch paths the Task fires before the View loads or after a UserDefault has clamped the toggle. UserDefault `lemon-mcp-enabled = true` is reliable; env var alone isn't. Workaround: set both.
- **Re-trigger fires on already-shipped revisions.** `hasNewComment(afterMarker)` returns true for *any* comment posted after the Lemon Report — including one Lemon itself already addressed in an earlier re-run. Right fix: post a *new* Lemon Report comment after each re-trigger completes so the marker advances. Until then, manually setting `🍋 Complete` and removing the trigger label after a re-run is required to stop the loop.
- **SwiftLM prompt cache full-hit returns empty content.** Identical input to `LocalLLM.classify()` produces zero output tokens, which decodes as `LocalLLMError.invalidResponse`. The error now has a descriptive `errorDescription`, but the structural fix is to cache-bust the user message (e.g. append a short timestamp suffix) when the caller wants a fresh verdict.

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

API credentials (Linear API key, GitHub PAT) are sensitive and live in Keychain; everything else is UserDefaults.

| Value | Storage | Key |
|-------|---------|-----|
| Linear API key | Keychain | `lemon-linear-key` |
| GitHub PAT | Keychain | `lemon-github-token` |
| Linear user ID | UserDefaults | `lemon-linear-user-id` |
| GitHub login | UserDefaults | `lemon-github-user` |
| Workspace pairs (JSON) | UserDefaults | `lemon-workspace-pairs` |

`KeychainStore.swift` handles all reads and writes. **Never** store secrets anywhere except Keychain — the `LEMON_*` env-var bypass under "Running Lemon unattended" is the one opt-in exception, for headless dev runs.

Workspace config is a JSON array of `WorkspacePair` objects — each a `SourceConfig` (Linear or GitHub) plus a `WorkspaceMapping` (match key → local repo/folder). Capped at 10, stored under `lemon-workspace-pairs`. The legacy `lemon-workspace-config` (a `WorkspaceRepo` array) migrates to one Linear pair per repo on first read, gated by the `lemon-workspace-config-migrated-at` sentinel. See `Models.swift` for the exact Codable shapes.

## Rules

- **Never** `git add -A` or `git add .` — stage explicit paths
- **Never** store secrets anywhere except Keychain
- All subprocesses must `cd /tmp` first (or use an explicit working directory) — launching from the home directory triggers macOS permission popups for Music, Contacts, etc.
- macOS 26 only
