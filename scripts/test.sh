#!/usr/bin/env bash
# ClaudeMix test runner
# Usage: ./scripts/test.sh [unit|e2e|all]
#
# Requires: bats-core, bats-support, bats-assert, bats-file
# Install:  brew install bats-core
# Helpers:  mkdir -p /tmp/bats-libs && \
#           git clone --depth 1 https://github.com/bats-core/bats-support.git /tmp/bats-libs/bats-support && \
#           git clone --depth 1 https://github.com/bats-core/bats-assert.git /tmp/bats-libs/bats-assert && \
#           git clone --depth 1 https://github.com/bats-core/bats-file.git /tmp/bats-libs/bats-file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export BATS_LIB_PATH="${BATS_LIB_PATH:-/tmp/bats-libs}"

if ! command -v bats >/dev/null 2>&1; then
  echo "Error: bats-core not installed. Run: brew install bats-core" >&2
  exit 1
fi

if [[ ! -d "$BATS_LIB_PATH/bats-support" ]]; then
  echo "Error: bats helpers not found at $BATS_LIB_PATH" >&2
  echo "Run:" >&2
  echo "  mkdir -p $BATS_LIB_PATH" >&2
  echo "  git clone --depth 1 https://github.com/bats-core/bats-support.git $BATS_LIB_PATH/bats-support" >&2
  echo "  git clone --depth 1 https://github.com/bats-core/bats-assert.git $BATS_LIB_PATH/bats-assert" >&2
  echo "  git clone --depth 1 https://github.com/bats-core/bats-file.git $BATS_LIB_PATH/bats-file" >&2
  exit 1
fi

suite="${1:-all}"

case "$suite" in
  unit)
    echo "Running unit tests..."
    bats "$PROJECT_ROOT/tests/unit/"
    ;;
  e2e)
    echo "Running e2e tests..."
    bats "$PROJECT_ROOT/tests/e2e/"
    ;;
  all)
    echo "Running all tests..."
    bats "$PROJECT_ROOT/tests/unit/" "$PROJECT_ROOT/tests/e2e/"
    ;;
  *)
    echo "Usage: $0 [unit|e2e|all]" >&2
    exit 1
    ;;
esac
