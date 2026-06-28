.PHONY: build-image open smoke-test help ui build-ui smoke watch test integration-test loop \
        sandbox sandbox-init sandbox-issue sandbox-show sandbox-reset sandbox-test

UI_BUILD_DIR := /tmp/lemon-build
UI_APP       := $(UI_BUILD_DIR)/Lemon.app
UI_PROJECT   := app/Lemon.xcodeproj
UI_SCHEME    := Lemon

help:
	@echo "  make build-image      Build lemon-worker:latest (requires apple/container)"
	@echo "  make open             Open Lemon.xcodeproj in Xcode"
	@echo "  make smoke-test       Run a test container run (requires secrets in Keychain)"
	@echo ""
	@echo "UI iteration:"
	@echo "  make build-ui         Incremental Swift build → $(UI_BUILD_DIR)"
	@echo "  make smoke            Smoke only (no rebuild) — screenshot every UI state"
	@echo "  make ui               build-ui + smoke (~8s) — main loop command"
	@echo "  make watch            Auto-run 'make ui' on every .swift save (needs fswatch)"
	@echo ""
	@echo "Testing:"
	@echo "  make test             XCTest suite (Keychain, LinearClient, GemmaResponse,"
	@echo "                        LocalLLM, WorktreeRunner)"
	@echo "  make integration-test Shell: tmux lifecycle + mock Gemma server + claude -p"
	@echo "  make loop             Full validation: build-ui + test + smoke"
	@echo ""
	@echo "Workflow sandbox (side-effect-free, no claude tokens):"
	@echo "  make sandbox-init     Create /tmp/lemon-sandbox fixtures + throwaway git workspace"
	@echo "  make sandbox-issue    File a 🍋 fixture issue (T=\"title\" B=\"body\")"
	@echo "  make sandbox          build-ui + relaunch Lemon in sandbox mode (fake-claude)"
	@echo "  make sandbox-test     build-ui + drive one issue end-to-end with assertions"
	@echo "  make sandbox-show     Print fixture issues' labels + comments"
	@echo "  make sandbox-reset    Wipe and re-init the sandbox"

build-ui:
	@xcodebuild \
	  -project $(UI_PROJECT) \
	  -scheme $(UI_SCHEME) \
	  -configuration Debug \
	  ONLY_ACTIVE_ARCH=YES \
	  CONFIGURATION_BUILD_DIR=$(UI_BUILD_DIR) \
	  OTHER_SWIFT_FLAGS="-warnings-as-errors" \
	  build 2>&1 | grep -E "^(.*error:|.*warning:.*error|BUILD)" | head -20

smoke:
	@scripts/smoke-test.sh

ui: build-ui smoke

test:
	@xcodebuild \
	  -project $(UI_PROJECT) \
	  -scheme $(UI_SCHEME) \
	  -configuration Debug \
	  ONLY_ACTIVE_ARCH=YES \
	  OTHER_SWIFT_FLAGS="-warnings-as-errors" \
	  -destination 'platform=macOS' \
	  test 2>&1 | grep -E "(Test Case|Test Suite|error:|FAIL|PASS|BUILD)" | head -60

integration-test:
	@scripts/integration-test.sh

loop: build-ui test smoke

# --- Workflow sandbox -------------------------------------------------------
# File-backed tracker (MockIssueClient) + throwaway git workspace + fake-claude,
# so the full plan→build→PR loop runs with no GitHub/Linear traffic and no
# claude tokens. See CLAUDE.md → "Workflow sandbox".
FAKE_CLAUDE := $(abspath scripts/fake-claude.sh)

sandbox-init:
	@scripts/sandbox.sh init

sandbox-issue:
	@scripts/sandbox.sh issue "$(T)" "$(B)"

sandbox-show:
	@scripts/sandbox.sh show

sandbox-reset:
	@scripts/sandbox.sh reset

sandbox: build-ui
	@pkill -f 'Lemon.app/Contents/MacOS/Lemon' 2>/dev/null; sleep 1 || true
	@[ -d /tmp/lemon-sandbox/workspace ] || scripts/sandbox.sh init
	@echo "Launching Lemon in sandbox mode (fake-claude, MCP on 127.0.0.1:8765)…"
	@LEMON_SANDBOX=1 LEMON_ENABLE_MCP=1 LEMON_CLAUDE_BIN="$(FAKE_CLAUDE)" \
	  $(UI_APP)/Contents/MacOS/Lemon >/tmp/lemon-sandbox/app.log 2>&1 &
	@echo "Running. File issues with 'make sandbox-issue', watch with 'make sandbox-show'."

sandbox-test: build-ui
	@scripts/sandbox-scenario.sh

watch:
	@which fswatch >/dev/null 2>&1 || (echo "Install: brew install fswatch" && exit 1)
	@echo "Watching app/Lemon/**/*.swift — running 'make ui' on change. Ctrl-C to stop."
	@fswatch -o app/Lemon | xargs -n1 -I{} sh -c 'echo "\n⟳  change detected, rebuilding…" && make ui'

build-image:
	container build -t lemon-worker:latest .

open:
	open app/Lemon.xcodeproj

smoke-test:
	container run --rm \
	  -e GITHUB_TOKEN="$$(security find-generic-password -s lemon-github-token -w)" \
	  -e LINEAR_API_KEY="$$(security find-generic-password -s lemon-linear-key -w)" \
	  -e ANTHROPIC_API_KEY="$$(security find-generic-password -s lemon-anthropic-key -w)" \
	  -e VERCEL_TOKEN="$$(security find-generic-password -s lemon-vercel-token -w)" \
	  -e MINTLIFY_TOKEN="$$(security find-generic-password -s lemon-mintlify-token -w)" \
	  -e LEMON_LINEAR_USER_ID="$$(security find-generic-password -s lemon-linear-user-id -w)" \
	  -e LEMON_CONFIG_REPO="$$(security find-generic-password -s lemon-config-repo -w)" \
	  -e LEMON_ISSUE_ID="TEST-1" \
	  -e LEMON_ISSUE_TITLE="Test bootstrap" \
	  -e LEMON_ISSUE_BODY="This is a smoke test. Classify as out of scope and stop." \
	  -v ~/.ssh/id_lemon:/root/.ssh/id_lemon:ro \
	  lemon-worker:latest
