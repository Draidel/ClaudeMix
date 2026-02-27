# tests/test_helper/common.bash
# Shared helpers for ClaudeMix bats tests.

# Load bats helpers
load "${BATS_LIB_PATH:-/tmp/bats-libs}/bats-support/load"
load "${BATS_LIB_PATH:-/tmp/bats-libs}/bats-assert/load"

# ── Project paths ────────────────────────────────────────────────────────────

CLAUDEMIX_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/.." && pwd)"
CLAUDEMIX_BIN="$CLAUDEMIX_ROOT/bin/claudemix"
CLAUDEMIX_LIB="$CLAUDEMIX_ROOT/lib"

# ── Source helpers ───────────────────────────────────────────────────────────

# Source lib/core.sh (and optionally other libs) into the test shell.
# This gives tests direct access to functions like sanitize_name, has_cmd, etc.
source_core() {
  # Prevent set -euo pipefail from killing test runner
  set +euo pipefail 2>/dev/null || true
  source "$CLAUDEMIX_LIB/core.sh"
}

source_lib() {
  source_core
  source "$CLAUDEMIX_LIB/worktree.sh"
  source "$CLAUDEMIX_LIB/session.sh"
  source "$CLAUDEMIX_LIB/hooks.sh"
  source "$CLAUDEMIX_LIB/merge-queue.sh"
}

# ── Test repo helpers ────────────────────────────────────────────────────────

# Create a temporary git repo for e2e tests.
# Sets TEST_REPO to the path. Call cleanup_test_repo in teardown.
create_test_repo() {
  TEST_REPO="$(mktemp -d)"
  cd "$TEST_REPO" || return 1
  git init --quiet
  git config user.email "test@claudemix.dev"
  git config user.name "ClaudeMix Test"
  git commit --allow-empty -m "initial commit" --quiet
  git branch -M main
  export TEST_REPO
  export PROJECT_ROOT="$TEST_REPO"
}

# Clean up the test repo.
cleanup_test_repo() {
  if [[ -n "${TEST_REPO:-}" ]] && [[ -d "$TEST_REPO" ]]; then
    rm -rf "$TEST_REPO"
  fi
}

# ── Mock helpers ─────────────────────────────────────────────────────────────

# Create a mock command that succeeds (or fails with exit code).
# Args: $1 = command name, $2 = exit code (default 0), $3 = stdout output
mock_cmd() {
  local name="$1"
  local exit_code="${2:-0}"
  local output="${3:-}"
  local mock_dir="$TEST_REPO/.mocks"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/$name" << EOF
#!/usr/bin/env bash
${output:+printf '%s\\n' "$output"}
exit $exit_code
EOF
  chmod +x "$mock_dir/$name"
  export PATH="$mock_dir:$PATH"
}

# Remove a mock command.
unmock_cmd() {
  local name="$1"
  rm -f "$TEST_REPO/.mocks/$name"
}
