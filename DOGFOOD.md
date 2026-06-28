# DOGFOOD.md — operating Lemon on its own issues

This is the **operator workloop**: how a human (or an agent) drives Lemon to do real work
on the Lemon repo itself, end to end. It is the companion to two neighbours — keep them
straight:

- **[`LEMON.md`](LEMON.md)** is *injected into* the worktrees Lemon spawns; it tells the
  Claude session what the repo is and how to build it.
- **[`docs/llms.txt`](docs/llms.txt)** is the distilled, public teaching version of the
  self-monitoring / self-review model — the elevator pitch for an agent visiting lemon.living.
- **This file** is the full operator workloop — the human/agent-facing "how to *operate*
  Lemon" guide. If `llms.txt` is the *what*, this is the *how*.

All commands are relative to the repo root. No machine-specific paths — substitute your own
where a value is yours (a key file, a checkout location).

---

## The shape of a run

```
🍋 added → plan gate → (you approve) → build, Gemma watching → result gate → (you approve) → PR → 🍋 Complete
```

One `claude` session spans the whole thing; it switches `--permission-mode plan` →
`auto` at the plan gate. See [`WORKFLOW_DESIGN.md`](WORKFLOW_DESIGN.md) for the design and
`LEMON.md` for the state machine.

---

## 1. Pre-flight

Before launching Lemon to drive a run, get the tree green. CI treats warnings as errors and
runs lint as a separate job, so check all three:

```sh
# Build — warnings are errors
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" build

# Test
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" -destination 'platform=macOS' test

# Lint — the #1 PR-check failure; a clean build does NOT cover it
swiftformat app/Lemon app/LemonTests   # auto-fix, then commit the result
swiftlint lint --strict                 # must report 0 violations
```

Launch Lemon unattended (skips the GUI Keychain prompt, boots the MCP server):

```sh
# Inline key value wins over a *_FILE path and avoids a TCC prompt each launch.
LEMON_LINEAR_KEY="$(cat <your-linear-key-file>)" LEMON_ENABLE_MCP=1 \
  /tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon &
```

- Direct exec propagates env vars more reliably than `open -a` on macOS 26.
- **MCP enable caveat:** `LEMON_ENABLE_MCP=1` alone can miss its window. If the server
  doesn't bind on `127.0.0.1:8765`, also set the UserDefault:
  `defaults write rocks.harpy.lemon lemon-mcp-enabled -bool true`, then relaunch.

The build → kill → relaunch loop (build to `/tmp/lemon-build`, then exec):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CONFIGURATION_BUILD_DIR=/tmp/lemon-build \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" build
pkill -f 'Lemon.app/Contents/MacOS/Lemon'; sleep 2
LEMON_LINEAR_KEY="$(cat <your-linear-key-file>)" LEMON_ENABLE_MCP=1 \
  /tmp/lemon-build/Lemon.app/Contents/MacOS/Lemon &
```

> ⚠️ The `pkill` pattern above is scoped to the app binary on purpose. Do **not** broaden it
> to `pkill -f Lemon` — that can kill a Lemon-managed session you (or another run) are inside.

---

## 2. Trigger a run

Tag an issue with **🍋**. Lemon picks it up on the next poll (15s active / 45s idle), cuts
a worktree, writes `LEMON_CONTEXT.md`, and launches `claude` in plan mode.

On **GitHub under lockdown** (default on for GitHub), a run requires *both* signals:

- the issue is **assigned to you**, and
- the **🍋 label was applied by you** (the labeler is checked via the events API).

So "assigned-to-you AND 🍋 AND labeled-by-you" — an outsider labelling a public issue can't
drive a run. Linear can't cheaply query the labeler, so it leans on the `assignee`/`userId`
queue (fails open, with an author-trust fallback in lockdown). Untrusted issue/comment text is
wrapped as data, never instructions.

---

## 3. Monitor a live run

**Over MCP** (read-shaped tools, safe for an observe-only role):

```sh
# What does Gemma think right now? (read-only classify)
curl -sS -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"force_classify","arguments":{"id":"<issue-id>"}}}'
```

`force_classify`, `get_pane_log`, `get_session`, `list_sessions`, `get_swiftlm_log` are all
read-shaped. `force_classify` accepts `act=true` to classify *and* execute the verdict on
demand (clear a prompt without waiting for the silence timer).

**Over tmux** — the sessions run on a private tmux server named `lemon`:

```sh
tmux -L lemon list-sessions
tmux -L lemon capture-pane -p -t <session-name>      # snapshot the live pane
```

**Gemma's verdicts and timing**, straight from the logs:

```sh
# Verdicts as SwiftLM emits them:
grep "srv  generate" /tmp/lemon-swiftlm.log | tail -10 | sed 's/srv  generate: id 0 | //'

# Per-session classify timing + summary from Lemon's os.Logger:
log show --predicate 'subsystem == "com.lemon.app"' --last 5m --info \
  | grep -E 'gemma|Retrigger|Poll'
```

Gemma is invoked on **silence**, not a timer: ~120s of quiet in the pane (counted by
*non-empty lines*, not bytes — ANSI cursor redraws inflate bytes without adding output) **and**
≥180s since the last classify. A stable pane hash short-circuits a repeat classify, so a stuck
screen can't drive a loop.

---

## 4. The two gates

- **Plan gate.** When the session parks at `.planReview`, the plan is posted to the issue and
  the label is `🍋 Waiting`. Approve it from the popover button, via the **`approve_gate`** MCP
  tool (`decision=approve`), or remote control. Approval send-keys **"1"** ("Yes, and use auto
  mode") and the same session continues into the build. Request changes (`decision=request_changes`,
  send-keys "4") makes Claude re-plan. A `🍋 auto` label on the issue skips the plan gate.
- **Result gate (opt-in).** If the build writes `/tmp/lemon-result-{slug}.md` instead of
  opening the PR, Lemon parks at `.resultReview`. Approve the same way; the session then opens
  the PR itself. Absent that sentinel, the 🍋 Complete → report → cleanup path runs unchanged.

---

## 5. Known failure modes & salvage

| Symptom | Cause | Recovery |
|---------|-------|----------|
| Session stuck `Waiting` while Claude is clearly still building | **Gate desync** — human approve sent "1" but `planGatePhase` didn't consume the gate sentinel; runner stopped tracking. | Confirm the build is live (`tmux -L lemon capture-pane`). Let it finish; reconcile labels on next poll. Underlying fix tracked in repo memory. |
| Long silence, no prompt on screen, `🍋` unmoved | **Session-limit stall** — `claude` hit a Max usage wall and parked quietly. | Gemma should detect → notify → auto-resume by sending text **then a separate Enter**. If not, send-keys the resume manually (text and Enter as two keystrokes). |
| Lemon pinned ~140% CPU, SwiftLM wedged at prefill | **Unbounded classify prompt** — a huge ANSI pane log (≈0 newlines) blew past the token budget. | Already mitigated by char/token caps after ANSI strip; if seen, kill the wedged classify and confirm the input-bounding path is in the running build. |
| A real session exits `127` right after launch | **Sandbox env leak** — a leftover sandbox tmux server kept `LEMON_SANDBOX`/`LEMON_CLAUDE_BIN` in its global env; the real session inherited a deleted `fake-claude`. | `tmux -L lemon kill-server` **only when no real session is running**, then relaunch. Never do this from inside a managed session. |
| The agent kills its own session mid-build | **Self-kill** — a Lemon-spawned `claude` ran a sandbox teardown script (which does `tmux kill-server` + `pkill Lemon`) from inside its own session. | Don't run sandbox teardown inside a managed session (see §7). The injected `LEMON_CONTEXT.md` should already warn against it. |

---

## 6. Sandbox vs real

The **sandbox** mocks the two expensive, irreversible parts of the loop — the tracker and
`claude` — so the full `Orchestrator → WorktreeRunner` lifecycle runs free and side-effect-free.
Use it to get the plan/result-gate workflow and Gemma prompts right without spending tokens or
touching a real tracker.

```sh
make sandbox-init                          # fixtures + throwaway git workspace (once)
make sandbox                               # relaunch Lemon against fixtures + fake-claude
make sandbox-issue T="Add hello" B="…"     # drop a 🍋 fixture issue; next poll picks it up
make sandbox-show                          # print each fixture's labels + comments
make sandbox-test                          # build + drive one issue end-to-end WITH ASSERTIONS
make sandbox-reset                         # wipe and re-init
```

`make sandbox-test` (`scripts/sandbox-scenario.sh`) is the asserting regression check for the
full plan-gate lifecycle. To truth-check against a **real** `claude` (costs tokens), launch with
`LEMON_SANDBOX=1` but *without* `LEMON_CLAUDE_BIN` — the fixture workspace is a real git repo, so
worktrees and `gh` (against a throwaway) behave normally.

---

## 7. The one hard rule for agents

If you are an agent reading this from *inside* a Lemon-managed tmux session (your
`LEMON_CONTEXT.md` will say so), **never run Lemon teardown** — it kills the session you are
running in:

- No `make sandbox*` / `scripts/sandbox*.sh`
- No `tmux kill-server` / `tmux kill-session` / `pkill -f Lemon`

To validate your work, use plain `xcodebuild`, `make test`, or `make build-ui` instead.
