#!/usr/bin/env bats
# E2E tests for worktree operations

setup() {
  load '../test_helper/common'
  source_lib
  create_test_repo

  # Set config defaults
  CFG_BASE_BRANCH="main"
  CFG_WORKTREE_DIR=".claudemix/worktrees"
  CFG_MERGE_TARGET="main"
  mkdir -p "$TEST_REPO/$CFG_WORKTREE_DIR"
  mkdir -p "$TEST_REPO/.claudemix/sessions"
}

teardown() {
  cleanup_test_repo
}

@test "worktree_create: creates worktree directory" {
  worktree_create "test-session"
  [[ -d "$TEST_REPO/$CFG_WORKTREE_DIR/test-session" ]]
}

@test "worktree_create: creates branch with prefix" {
  worktree_create "test-session"
  run git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/claudemix/test-session"
  assert_success
}

@test "worktree_create: sets WORKTREE_PATH" {
  worktree_create "test-session"
  [[ "$WORKTREE_PATH" == "$TEST_REPO/$CFG_WORKTREE_DIR/test-session" ]]
}

@test "worktree_create: reuses existing worktree" {
  worktree_create "test-session"
  # Second call should succeed without error
  worktree_create "test-session"
  [[ -d "$TEST_REPO/$CFG_WORKTREE_DIR/test-session" ]]
}

@test "worktree_exists: returns true for existing worktree" {
  worktree_create "test-session"
  run worktree_exists "test-session"
  assert_success
}

@test "worktree_exists: returns false for non-existing worktree" {
  run worktree_exists "nonexistent"
  assert_failure
}

@test "worktree_remove: removes worktree directory" {
  worktree_create "test-session"
  worktree_remove "test-session"
  [[ ! -d "$TEST_REPO/$CFG_WORKTREE_DIR/test-session" ]]
}

@test "worktree_remove: with keep-branch preserves branch" {
  worktree_create "test-session"
  worktree_remove "test-session" "keep-branch"
  run git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/claudemix/test-session"
  assert_success
}

@test "worktree_remove: without keep-branch deletes branch" {
  worktree_create "test-session"
  worktree_remove "test-session"
  run git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/claudemix/test-session"
  assert_failure
}

@test "worktree_list: lists created worktrees" {
  worktree_create "session-a"
  worktree_create "session-b"
  run worktree_list
  assert_success
  assert_output --partial "session-a"
  assert_output --partial "session-b"
}
