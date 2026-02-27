#!/usr/bin/env bats
# E2E tests for merge queue operations

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
  CFG_CLAUDE_FLAGS=""
  mkdir -p "$TEST_REPO/$CFG_WORKTREE_DIR"
  mkdir -p "$TEST_REPO/.claudemix/sessions"
}

teardown() {
  cleanup_test_repo
}

@test "merge_queue_list: shows no branches message when empty" {
  run merge_queue_list
  assert_success
  assert_output --partial "No ClaudeMix branches"
}

@test "merge_queue_list: shows branches with ahead/behind counts" {
  # Create a claudemix branch with a commit
  git -C "$TEST_REPO" checkout -b "claudemix/test-branch" --quiet
  git -C "$TEST_REPO" commit --allow-empty -m "test commit" --quiet
  git -C "$TEST_REPO" checkout main --quiet

  run merge_queue_list
  assert_success
  assert_output --partial "claudemix/test-branch"
  assert_output --partial "+1"
}
