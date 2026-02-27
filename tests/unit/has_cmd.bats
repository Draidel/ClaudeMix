#!/usr/bin/env bats
# Unit tests for has_cmd() from lib/core.sh

setup() {
  load '../test_helper/common'
  source_core
}

@test "has_cmd: finds existing command (bash)" {
  run has_cmd bash
  assert_success
}

@test "has_cmd: fails for non-existent command" {
  run has_cmd nonexistent_command_12345
  assert_failure
}

@test "has_cmd: finds builtins (cd)" {
  run has_cmd cd
  assert_success
}
