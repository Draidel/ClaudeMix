#!/usr/bin/env bats
# Unit tests for format_time() from lib/core.sh

setup() {
  load '../test_helper/common'
  source_core
}

@test "format_time: returns non-empty output for ISO timestamp" {
  run format_time "2026-02-27T14:30:00Z"
  assert_success
  [[ -n "$output" ]]
}

@test "format_time: output contains expected date components" {
  run format_time "2026-02-27T14:30:00Z"
  assert_success
  # Should contain at least the date/time portion (varies by platform)
  [[ "$output" =~ 14:30 ]] || [[ "$output" =~ "Feb" ]] || [[ "$output" =~ "2026-02-27" ]]
}
