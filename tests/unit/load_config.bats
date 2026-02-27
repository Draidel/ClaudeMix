#!/usr/bin/env bats
# Unit tests for load_config() from lib/core.sh

setup() {
  load '../test_helper/common'
  source_core
  create_test_repo
  mkdir -p "$TEST_REPO/.claudemix/worktrees" "$TEST_REPO/.claudemix/sessions"
}

teardown() {
  cleanup_test_repo
}

@test "load_config: uses defaults when no config file" {
  load_config
  assert_equal "$CFG_MERGE_STRATEGY" "squash"
  assert_equal "$CFG_PROTECTED_BRANCHES" "main"
}

@test "load_config: parses key-value pairs" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: make test
merge_strategy: rebase
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "make test"
  assert_equal "$CFG_MERGE_STRATEGY" "rebase"
}

@test "load_config: ignores comments" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
# This is a comment
validate: pnpm lint
# Another comment
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "pnpm lint"
}

@test "load_config: handles colons in values" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: npm run test:unit
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "npm run test:unit"
}

@test "load_config: ignores unknown keys" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
unknown_key: some_value
validate: pnpm test
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "pnpm test"
}
