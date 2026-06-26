# Contributing to Lemon

Thanks for your interest! Lemon is a personal workflow-orchestration menu-bar app
for macOS. This guide covers how to build, test, and submit changes.

## Requirements

- **macOS 26** (Tahoe) — Lemon targets macOS 26 only.
- **Xcode 26** — needed for the macOS 26 SDK.
- Optional for the integration tests: `tmux`, `python3`, and the `claude` CLI.

## Build & test

Warnings are treated as errors; both build and tests must be clean before a PR
is ready.

```sh
# Build
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" build

# Test
xcodebuild -project app/Lemon.xcodeproj -scheme Lemon -configuration Debug \
  OTHER_SWIFT_FLAGS="-warnings-as-errors" -destination 'platform=macOS' test
```

Convenience targets (see the `Makefile`):

```sh
make ui     # incremental build + UI smoke screenshots (no Keychain/Linear needed)
make test   # XCTest suite
make loop   # build-ui + test + smoke — full local validation (~30s)
```

The UI smoke test (`--smoke-test`) screenshots every UI state without touching the
Keychain, Linear, or a running tmux session — use it to iterate on views.

## Pull requests

1. Branch off `main` (e.g. `feat/...`, `fix/...`, `chore/...`).
2. Keep changes focused; match the surrounding code's style and the design-token
   rules in `CLAUDE.md` (no hardcoded colors — use `LD.*`).
3. Ensure a clean build **and** passing tests. CI runs both on every PR.
4. For UI changes, include before/after screenshots from the smoke test.
5. Open the PR against `main`. `main` is protected: PRs require a passing CI check
   and review approval before merge.

## Security

Never commit secrets. The only sensitive value (your issue-tracker API key) lives
in the macOS Keychain — see `KeychainStore.swift`. To report a vulnerability, see
[SECURITY.md](SECURITY.md).
