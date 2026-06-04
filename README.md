<div align="center">

<img src="docs/img/lemon-mini.png" alt="A lemon perched on a Mac mini" width="420">

# 🍋 Lemon

**A personal workflow orchestration menu-bar app for Claude Code + Linear, leveraging Gemma 4 on device.**
*Made for the Mac mini sitting on your desk.*

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-F7C842?style=flat-square&labelColor=1a1714)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS_26+-1a1714?style=flat-square)]()
[![Silicon](https://img.shields.io/badge/silicon-Apple-1a1714?style=flat-square)]()
[![SwiftLM](https://img.shields.io/badge/SwiftLM-b648-EF6A48?style=flat-square)](https://github.com/SharpAI/SwiftLM)

[**Install**](#install) · [**How it works**](#how-it-works) · [**The 🍋 workflow**](#the--workflow) · [**Stack**](#stack--gratitude) · [**Releases**](https://github.com/frkline/lemon/releases)

</div>

---

Every coding-agent product I tried wanted to be **the agent** — wrap Claude in their UI, route the API through their servers, sell me an "AI developer." I already have Claude Code, and I already do the interesting parts: answering Claude's clarifying questions, shaping the plan, reviewing the diff. What I *didn't* want to keep doing by hand was the workflow bureaucracy around it — scanning Linear for what's next, spinning up worktrees, dropping in the right context, transitioning labels, posting the PR comment back.

Lemon is that menu-bar glue. It runs `claude` (your login, your machine), watches the pane with a tiny on-device Gemma 4 classifier so you don't have to babysit every "Trust this MCP server?" prompt, and routes the result back to Linear. You stay in the loop where it matters; Lemon handles the parts you'd otherwise click-through. **Lemon isn't an AI agent product — the intelligence is Claude Code, and the judgment is yours.**

## What Lemon is, and isn't

| ✅ It is | ❌ It isn't |
|---|---|
| A menu-bar **orchestrator** that decides when to start Claude Code | An AI agent product — the agent is Claude Code |
| **Glue** between your Linear queue and your Claude Code CLI | A Claude reseller — Lemon never proxies your API traffic |
| A **local Gemma 4 classifier** for obvious-confirmation auto-accept and unstick-dumb-prompts | A multi-tenant SaaS |
| Built for **one developer** running it | A competitor to Anthropic, Linear, or anything else |

## Install

```sh
brew install hf tmux gh claude-code             # Runtime prereqs
```

**Direct download** — signed `.app` from [GitHub Releases](https://github.com/frkline/lemon/releases). Drag to `/Applications`.

**From source** *(macOS 26 · Apple Silicon · Xcode 26)*:

```sh
git clone https://github.com/frkline/lemon
cd lemon && open app/Lemon.xcodeproj
```

Build target **Lemon** in Xcode. The app drops itself in the menu bar; first launch runs the onboarding wizard, which gates Continue on a downloaded Gemma 4 (E2B or E4B) and a SwiftLM binary.

| | Requirement |
|---|---|
| **OS** | macOS 26 · Apple Silicon |
| **Gemma 4 E2B** | ~4 GB on disk · runs on 16 GB Macs |
| **Gemma 4 E4B** *(recommended)* | ~6 GB on disk · 24 GB+ RAM |
| **Other** | `tmux`, `hf` CLI, `gh`, authenticated `claude` |

## How it works

<div align="center">
<img src="docs/img/live-list.png" alt="The Lemon popover with one active session" width="640">
</div>

```
┌──────────────┐ poll  ┌──────────────┐ launch  ┌──────────────┐
│   Linear     │──────▶│  Lemon.app   │────────▶│ tmux + claude │
│    queue     │◀──────│ (menu bar)   │◀────────│  (your CLI)   │
└──────────────┘ label └──────┬───────┘  pane   └──────┬───────┘
                              │ log                    │
                              ▼                        ▼
                       ┌──────────────┐         ┌──────────────┐
                       │ Gemma 4 on   │ JSON    │ git worktree │
                       │ Apple Silicon│◀────────│ /tmp/lemon-* │
                       │   (SwiftLM)  │         └──────────────┘
                       └──────────────┘
```

1. **Label** a Linear issue with 🍋.
2. **Orchestrator** picks it up on the next poll (15 s active, 45 s idle).
3. A **git worktree** spins up at `/tmp/lemon-{id}`; `LEMON_CONTEXT.md` is written with the issue body, your team's `LEMON.md`, and the completion checklist.
4. A **terminal window** opens running `claude --enable-auto-mode --remote-control`. Lemon prefers iTerm2, falls back to Terminal.app.
5. **Gemma 4** runs locally via SwiftLM + MLX. After 2 minutes of pane silence, Lemon hands it the tail of the log and asks "what's happening?" — the classifier answers obvious confirmation prompts (`y/n/yes/no/1-9/Enter/Escape`) through a hard allowlist and raises 🍋 Waiting for anything ambiguous.
6. When Claude sets **🍋 Complete**, Lemon posts a Linear comment with the PR link and a summary, then cleans up the worktree.
7. **Reply** to the Lemon comment to re-trigger a revision pass — Lemon reuses the branch.

## The 🍋 workflow

<div align="center">
<img src="docs/img/lemon-linear.png" alt="Lemon loves Linear" width="260">
<p><sub><i>For Linear, who already knows what work needs doing.</i></sub></p>
</div>

Lemon's entire surface in your Linear workspace is **four labels** and **one comment**.

| Label | Set by | Meaning |
|---|---|---|
| `🍋` | You | Trigger — Lemon picks this up |
| `🍋 In Progress` | Lemon | Worktree active, Claude running |
| `🍋 Waiting` | Claude / Gemma | Paused, needs your input |
| `🍋 Complete` | Claude | PR open, Lemon report posted |

Labels are auto-provisioned in every team you have access to on first launch — if your Linear admin already created custom 🍋 labels with the same names, Lemon adopts them (fetch-or-create).

> **When it calls for you, it calls for you — wherever you are.**
> Claude Code launches with `--remote-control`, so when Gemma can't resolve a prompt and 🍋 Waiting fires, a push notification lands in the **Claude iOS app** on your phone. You answer the question natively — from the couch, from a walk, from a park bench while your kid is on the swings — and the session keeps going. Lemon and Gemma absorbed the routine bits so the only thing that reaches you is the one decision that actually needs you.

## Local AI is not optional

<div align="center">
<img src="docs/img/setup-3-localai.png" alt="Local AI onboarding step with Gemma model and SwiftLM runner both ready" width="380">
</div>

The whole point of Lemon is the silence detector + auto-accept + unstick-dumb-prompts trio. Without a local model running, the 🍋 Waiting auto-pause and confirmation auto-accept paths don't fire. So onboarding gates Continue on:

- A downloaded **Gemma 4** quant from [`mlx-community`](https://huggingface.co/mlx-community) (E2B at ~4 GB or E4B at ~6 GB)
- A signed **SwiftLM** binary from [`SharpAI/SwiftLM`](https://github.com/SharpAI/SwiftLM) (currently pinned to build `b648`)

Both are pulled inside the wizard. Nothing is built from source.

A **Self-test** button in Settings boots the runner, fires one `classify()` call, and reports the actual response. If anything fails, the error tooltip carries the `log stream` predicate ready to paste into Console.app.

## Bonus: nest `/loop` inside

Lemon is itself a hand-coded `/loop` — `goal = ship a PR for this Linear issue`. The Orchestrator polls, Gemma watches the pane, the session keeps going until 🍋 Complete fires. That same pattern is broadly useful inside a session, especially for work that benefits from iteration over one-shot:

- **Polish** — UI / docs / a tricky code path: try, look, refine
- **Reviews** — diffs, PRs, modules: one finding per tick
- **Refactors** — when you can't enumerate every call site upfront
- **Bug-hunting sweeps** — fix one, run tests, find the next
- **Test backfill** — write one, watch it pass, find the next gap
- **Exploration** — when the next move depends on what the last move just told you

Tell Claude to lean on `/loop` in your team's `LEMON.md` when the issue calls for it. You get nested iteration: Lemon iterates the Linear queue, Claude iterates inside each ticket. *(This README, the docs site, and most of the bug fixes in this repo were built by running `/loop` against an open-ended "drive Lemon to fully baked" goal.)*

## Privacy & egress

**Lemon-the-binary** only ever talks to **Linear's GraphQL** for label and comment operations. That's the only network call the orchestrator itself makes.

Everything else flows through tools you launched and authenticated:

| What | Where it goes |
|---|---|
| Issues, labels, comments | Linear API |
| Claude API traffic | Your `claude` CLI → Anthropic (Lemon never sees the bytes) |
| `gh pr create`, `git push` | GitHub, from inside the worktree |
| Gemma 4 inference | **On your Mac's GPU.** Never leaves the machine. |
| Model + runner downloads | **Once**, during onboarding, from HuggingFace + GitHub releases |
| Telemetry | None. Zero. No analytics SDK. |

The Linear API key is stored in macOS **Keychain**, not a file. Workspace paths live in UserDefaults. Session logs land in `/tmp/lemon-log-{id}.txt` and are wiped on cleanup.

## Stack & gratitude

None of this is from scratch. Lemon is a small assembly of other people's good ideas.

| | Project | What |
|---|---|---|
| **The agent** | [Claude Code](https://claude.com/code) (Anthropic) | The intelligence. Lemon launches and watches; Claude codes. |
| **The runtime** | [SwiftLM](https://github.com/SharpAI/SwiftLM) (SharpAI, `b648`) | OpenAI-compatible MLX inference server in pure Swift. |
| **The framework** | [MLX](https://github.com/ml-explore/mlx) (Apple) | Open-source ML for Apple Silicon. SwiftLM maps Gemma onto Metal through it. |
| **The weights** | [`mlx-community`](https://huggingface.co/mlx-community) on HuggingFace | The quantized [`gemma-4-e4b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit) / [`gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) |
| **The surface** | [Linear](https://linear.app) | The issue tracker that's the entire Lemon UI for "what's next?" |

**More silicon than you know what to do with?** [oMLX](https://omlx.ai) — same on-device idea, scaled up to a Mac Studio's larger MoE models.

## Development

```sh
make ui                # incremental build + smoke screenshots (~8 s)
make watch             # auto-rebuild + smoke on every .swift save
make test              # XCTest suite
make integration-test  # shell tests: tmux lifecycle + mock Gemma + claude -p
```

UI iteration happens via the smoke test (`scripts/smoke-test.sh`), which drives every screen in-process and dumps PNGs to `/tmp/lemon-smoke/latest/`. See [`CLAUDE.md`](CLAUDE.md) for the full architecture, smoke loop, and contributor guide.

## License

Apache 2.0. See [`LICENSE`](LICENSE).

---

<div align="center">
<sub><i>Built by <a href="https://github.com/frkline">Frank Kline</a> as personal workflow tooling. Pull requests welcome.</i></sub>
</div>
