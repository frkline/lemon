---
title: CI's lint job is the #1 PR-check failure — run swiftformat + swiftlint before pushing
type: instruction
status: active
date: 2026-06-28
related: [[next-session-playbook]]
---

CI (`.github/workflows/ci.yml`) runs **two** jobs: `build-test` *and* a separate
`lint` job. The `lint` job runs:

```sh
swiftformat --lint app/Lemon app/LemonTests   # lint mode — fails on any diff
swiftlint lint --strict                         # --strict → warnings are errors
```

A clean `xcodebuild` / `make test` does **not** cover this. Code that builds and
passes tests locally routinely fails `lint` on formatting/style — SwiftFormat rules
like `hoistAwait`, `wrapFunctionBodies`, `indent`, `trailingSpace`, `docComments`.
This is the **most common reason a PR's checks go red** here, and it bites
Lemon-spawned agent sessions especially: they run build+test but never the linters.

**How to apply:** before committing/finishing any Swift change, run

```sh
swiftformat app/Lemon app/LemonTests   # auto-fix, then commit the result
swiftlint lint --strict                 # must print "0 violations"
```

`swiftformat` (no `--lint`) edits in place; commit what it changes. The repo config
is `.swiftformat` (`--swiftversion 6.3`, `redundantSelf` disabled). This is mirrored
into the worktree instructions Lemon injects (`LEMON.md` → "Dev loop, build, test")
so spawned sessions self-correct.

_Discovered when PR #38 (issue #35) passed `build-test` but failed `lint` on
SwiftFormat violations in `Orchestrator.swift` + `WorktreeRunner.swift`._
