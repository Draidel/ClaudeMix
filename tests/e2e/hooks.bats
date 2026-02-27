#!/usr/bin/env bats
# E2E tests for hooks operations

setup() {
  load '../test_helper/common'
  source_lib
  create_test_repo

  # Set config defaults
  CFG_BASE_BRANCH="main"
  CFG_WORKTREE_DIR=".claudemix/worktrees"
  CFG_MERGE_TARGET="main"
  CFG_VALIDATE="echo ok"
  CFG_PROTECTED_BRANCHES="main,staging"
  CFG_MERGE_STRATEGY="squash"
  CFG_CLAUDE_FLAGS=""
  mkdir -p "$TEST_REPO/$CFG_WORKTREE_DIR"
  mkdir -p "$TEST_REPO/.claudemix/sessions"
}

teardown() {
  cleanup_test_repo
}

@test "hooks_install: creates hooks in .git/hooks (direct method)" {
  hooks_install
  local hooks_dir
  hooks_dir="$(git -C "$TEST_REPO" rev-parse --git-dir)/hooks"
  [[ -f "$hooks_dir/pre-push" ]]
}

@test "hooks_install: pre-push has ClaudeMix marker" {
  hooks_install
  local hooks_dir
  hooks_dir="$(git -C "$TEST_REPO" rev-parse --git-dir)/hooks"
  run grep "ClaudeMix" "$hooks_dir/pre-push"
  assert_success
}

@test "hooks_install: pre-push uses POSIX shebang" {
  hooks_install
  local hooks_dir
  hooks_dir="$(git -C "$TEST_REPO" rev-parse --git-dir)/hooks"
  local first_line
  first_line="$(head -1 "$hooks_dir/pre-push")"
  assert_equal "$first_line" "#!/bin/sh"
}

@test "hooks_uninstall: removes ClaudeMix hooks" {
  hooks_install
  hooks_uninstall
  local hooks_dir
  hooks_dir="$(git -C "$TEST_REPO" rev-parse --git-dir)/hooks"
  # If pre-push still exists, it shouldn't have ClaudeMix marker
  if [[ -f "$hooks_dir/pre-push" ]]; then
    run grep "ClaudeMix" "$hooks_dir/pre-push"
    assert_failure
  fi
}

@test "hooks_status: runs without error" {
  run hooks_status
  assert_success
  assert_output --partial "Git Hooks Status"
}
