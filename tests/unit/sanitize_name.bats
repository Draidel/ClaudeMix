#!/usr/bin/env bats
# Unit tests for sanitize_name() from lib/core.sh

setup() {
  load '../test_helper/common'
  source_core
}

@test "sanitize_name: keeps valid alphanumeric name" {
  run sanitize_name "auth-fix"
  assert_success
  assert_output "auth-fix"
}

@test "sanitize_name: keeps underscores" {
  run sanitize_name "my_session"
  assert_success
  assert_output "my_session"
}

@test "sanitize_name: replaces spaces with hyphens" {
  run sanitize_name "my session name"
  assert_success
  assert_output "my-session-name"
}

@test "sanitize_name: replaces special characters with hyphens" {
  run sanitize_name "fix@bug#123"
  assert_success
  assert_output "fix-bug-123"
}

@test "sanitize_name: strips leading hyphens" {
  run sanitize_name "---leading"
  assert_success
  assert_output "leading"
}

@test "sanitize_name: strips trailing hyphens" {
  run sanitize_name "trailing---"
  assert_success
  assert_output "trailing"
}

@test "sanitize_name: dies on empty input" {
  run sanitize_name ""
  assert_failure
  assert_output --partial "Invalid session name"
}

@test "sanitize_name: handles pure numbers" {
  run sanitize_name "42"
  assert_success
  assert_output "42"
}
