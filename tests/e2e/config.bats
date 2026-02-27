#!/usr/bin/env bats
# E2E tests for config operations

setup() {
  load '../test_helper/common'
  source_lib
  create_test_repo

  # Set config defaults
  CFG_BASE_BRANCH="main"
  CFG_WORKTREE_DIR=".claudemix/worktrees"
  CFG_MERGE_TARGET="main"
  CFG_VALIDATE=""
  CFG_PROTECTED_BRANCHES="main"
  CFG_MERGE_STRATEGY="squash"
  CFG_CLAUDE_FLAGS="--dangerously-skip-permissions"
}

teardown() {
  cleanup_test_repo
}

@test "ensure_claudemix_dir: creates directory structure" {
  ensure_claudemix_dir
  [[ -d "$TEST_REPO/.claudemix/worktrees" ]]
  [[ -d "$TEST_REPO/.claudemix/sessions" ]]
}

@test "ensure_claudemix_dir: adds to gitignore" {
  echo "# existing" > "$TEST_REPO/.gitignore"
  ensure_claudemix_dir
  run grep ".claudemix/" "$TEST_REPO/.gitignore"
  assert_success
}

@test "write_default_config: creates config file" {
  _detect_defaults
  local config_path="$TEST_REPO/.claudemix.yml"
  write_default_config "$config_path"
  [[ -f "$config_path" ]]
}

@test "write_default_config: round-trip with load_config" {
  CFG_VALIDATE="make test"
  CFG_MERGE_STRATEGY="rebase"
  _detect_defaults
  local config_path="$TEST_REPO/.claudemix.yml"
  write_default_config "$config_path"

  # Reset and reload
  CFG_VALIDATE=""
  CFG_MERGE_STRATEGY=""
  load_config

  assert_equal "$CFG_VALIDATE" "make test"
  assert_equal "$CFG_MERGE_STRATEGY" "rebase"
}
