#!/usr/bin/env bats
# Unit tests for detect_pkg_manager() from lib/core.sh

setup() {
  load '../test_helper/common'
  source_core
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "detect_pkg_manager: detects pnpm from lock file" {
  touch "$TEST_DIR/pnpm-lock.yaml"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "pnpm"
}

@test "detect_pkg_manager: detects pnpm from workspace file" {
  touch "$TEST_DIR/pnpm-workspace.yaml"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "pnpm"
}

@test "detect_pkg_manager: detects yarn from lock file" {
  touch "$TEST_DIR/yarn.lock"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "yarn"
}

@test "detect_pkg_manager: detects bun from lockb file" {
  touch "$TEST_DIR/bun.lockb"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "bun"
}

@test "detect_pkg_manager: detects bun from lock file" {
  touch "$TEST_DIR/bun.lock"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "bun"
}

@test "detect_pkg_manager: defaults to npm when no lock file" {
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "npm"
}

@test "detect_pkg_manager: pnpm takes priority over yarn" {
  touch "$TEST_DIR/pnpm-lock.yaml"
  touch "$TEST_DIR/yarn.lock"
  run detect_pkg_manager "$TEST_DIR"
  assert_success
  assert_output "pnpm"
}
