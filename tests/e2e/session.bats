#!/usr/bin/env bats
# E2E tests for session operations (without tmux/claude)

setup() {
  load '../test_helper/common'
  source_lib
  create_test_repo

  # Set config defaults
  CFG_BASE_BRANCH="main"
  CFG_WORKTREE_DIR=".claudemix/worktrees"
  CFG_MERGE_TARGET="main"
  CFG_VALIDATE=""
  CFG_CLAUDE_FLAGS=""
  CFG_PROTECTED_BRANCHES="main"
  CFG_MERGE_STRATEGY="squash"
  mkdir -p "$TEST_REPO/$CFG_WORKTREE_DIR"
  mkdir -p "$TEST_REPO/.claudemix/sessions"

  # Mock tmux and claude to prevent real launches
  mock_cmd tmux 0
  mock_cmd claude 0
}

teardown() {
  cleanup_test_repo
}

@test "session_list: shows no sessions message when empty" {
  run session_list "table"
  assert_success
  assert_output --partial "No active sessions"
}

@test "session_list: names format returns empty for no sessions" {
  run session_list "names"
  assert_success
  assert_output ""
}

@test "_session_save_meta: creates metadata file" {
  CFG_BASE_BRANCH="main"
  _session_save_meta "test-session" "$TEST_REPO/.claudemix/worktrees/test-session"
  [[ -f "$TEST_REPO/.claudemix/sessions/test-session.meta" ]]
}

@test "_session_save_meta: metadata contains expected fields" {
  CFG_BASE_BRANCH="main"
  _session_save_meta "test-session" "$TEST_REPO/.claudemix/worktrees/test-session"
  local meta="$TEST_REPO/.claudemix/sessions/test-session.meta"
  run grep "^name=test-session$" "$meta"
  assert_success
  run grep "^branch=claudemix/test-session$" "$meta"
  assert_success
}

@test "session_kill: removes metadata file" {
  # Create a worktree and metadata
  worktree_create "kill-test"
  _session_save_meta "kill-test" "$TEST_REPO/.claudemix/worktrees/kill-test"
  [[ -f "$TEST_REPO/.claudemix/sessions/kill-test.meta" ]]

  session_kill "kill-test"
  [[ ! -f "$TEST_REPO/.claudemix/sessions/kill-test.meta" ]]
}
