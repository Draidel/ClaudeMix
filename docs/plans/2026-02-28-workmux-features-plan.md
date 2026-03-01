# Workmux-Inspired Features — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 8 workmux-inspired features to ClaudeMix: global config, lifecycle hooks, file copy/symlink, pane layouts, open/close separation, --with-changes, --pr checkout, and live dashboard.

**Architecture:** All new features layer on top of the existing bash library structure. Config expansion (core.sh) is the foundation — every other feature depends on new CFG_* keys. Worktree lifecycle hooks and file operations extend worktree.sh. Session management (open/close, panes, flags) extends session.sh. Dashboard is a new lib/dashboard.sh. CLI routing, TUI, and completions are updated last.

**Tech Stack:** Bash (set -euo pipefail entry point, sourced libraries), tmux (pane layouts), git (worktrees), gh (PR checkout), gum (TUI fallback)

**Design doc:** `docs/plans/2026-02-28-workmux-features-design.md`

**Key constraints from CLAUDE.md:**
- Library files MUST NOT contain `set -euo pipefail`
- Use `var=$((var + 1))` not `((var++))` (set -e safety)
- Use `printf` not `echo` for output
- Use `die "message"` for fatal errors
- Use `log_info`/`log_ok`/`log_warn`/`log_error`/`log_debug` for logging
- Generated hooks must be POSIX (`#!/bin/sh`, no bashisms)
- Validate paths before `rm -rf`
- Sanitize config values before embedding in scripts
- Use `printf '%q'` for tmux command escaping
- Use `'HEREDOC'` (single-quoted) for literal content

---

## Task 1: Expand config globals and loading in core.sh

**Files:**
- Modify: `lib/core.sh:103-110` (config defaults section)
- Modify: `lib/core.sh:136-144` (load_config case statement)
- Modify: `lib/core.sh:209-261` (_validate_config)
- Modify: `lib/core.sh:265-278` (write_default_config)

**Step 1: Add new CFG_* global declarations**

Add after line 109 (`declare -g CFG_WORKTREE_DIR=""`) in `lib/core.sh`:

```bash
declare -g CFG_POST_CREATE=""
declare -g CFG_PRE_MERGE=""
declare -g CFG_PRE_REMOVE=""
declare -g CFG_COPY_FILES=""
declare -g CFG_SYMLINK_FILES=""
declare -g CFG_PANES=""
declare -g CFG_EDITOR="${EDITOR:-vim}"
declare -g CFG_DASHBOARD_REFRESH="2"
```

**Step 2: Add new cases in load_config()**

Add new cases in the `case "$key" in` block (after `worktree_dir)` line ~143):

```bash
        post_create)         CFG_POST_CREATE="$value" ;;
        pre_merge)           CFG_PRE_MERGE="$value" ;;
        pre_remove)          CFG_PRE_REMOVE="$value" ;;
        copy_files)          CFG_COPY_FILES="$value" ;;
        symlink_files)       CFG_SYMLINK_FILES="$value" ;;
        panes)               CFG_PANES="$value" ;;
        editor)              CFG_EDITOR="$value" ;;
        dashboard_refresh)   CFG_DASHBOARD_REFRESH="$value" ;;
```

**Step 3: Add validation for new config keys**

Add in `_validate_config()` after the existing `CFG_PROTECTED_BRANCHES` validation:

```bash
  # Validate lifecycle hook commands (same rules as validate)
  for hook_var in CFG_POST_CREATE CFG_PRE_MERGE CFG_PRE_REMOVE; do
    local hook_val="${!hook_var}"
    if [[ -n "$hook_val" ]]; then
      # shellcheck disable=SC2016
      if [[ "$hook_val" == *'$('* ]] || [[ "$hook_val" == *'`'* ]] \
        || [[ "$hook_val" == *';'* ]] || [[ "$hook_val" == *'|'* ]] \
        || [[ "$hook_val" == *'>'* ]] || [[ "$hook_val" == *'<'* ]] \
        || [[ "$hook_val" == *$'\n'* ]]; then
        log_warn "Unsafe characters in $hook_var config — rejecting"
        declare -g "$hook_var="
      fi
    fi
  done

  # Validate copy_files / symlink_files: no path traversal, no shell metacharacters
  for files_var in CFG_COPY_FILES CFG_SYMLINK_FILES; do
    local files_val="${!files_var}"
    if [[ -n "$files_val" ]]; then
      if [[ "$files_val" == *".."* ]] || [[ "$files_val" == /* ]]; then
        log_warn "Unsafe path in $files_var config — rejecting"
        declare -g "$files_var="
      fi
    fi
  done

  # Validate dashboard_refresh: must be a positive integer
  if [[ -n "$CFG_DASHBOARD_REFRESH" ]]; then
    if ! [[ "$CFG_DASHBOARD_REFRESH" =~ ^[0-9]+$ ]] || (( CFG_DASHBOARD_REFRESH < 1 )); then
      log_warn "Invalid dashboard_refresh '${CFG_DASHBOARD_REFRESH}' — using default 2"
      CFG_DASHBOARD_REFRESH="2"
    fi
  fi

  # Validate panes: reject shell metacharacters except | and / (layout operators)
  if [[ -n "$CFG_PANES" ]]; then
    # shellcheck disable=SC2016
    if [[ "$CFG_PANES" == *'$('* ]] || [[ "$CFG_PANES" == *'`'* ]] \
      || [[ "$CFG_PANES" == *';'* ]] || [[ "$CFG_PANES" == *'>'* ]] \
      || [[ "$CFG_PANES" == *'<'* ]]; then
      log_warn "Unsafe characters in panes config — rejecting"
      CFG_PANES=""
    fi
  fi
```

**Step 4: Update write_default_config()**

Add the new keys to the output in `write_default_config()`:

```bash
    printf '\n# Lifecycle hooks (run during worktree operations)\n'
    printf '# post_create: pnpm install && cp .env.example .env\n'
    printf '# pre_merge: pnpm test\n'
    printf '# pre_remove: echo cleaning up\n'
    printf '\n# Files to copy into new worktrees (comma-separated globs)\n'
    printf '# copy_files: .env,.env.local\n'
    printf '\n# Files to symlink into new worktrees (comma-separated globs)\n'
    printf '# symlink_files: node_modules\n'
    printf '\n# Pane layout: commands separated by | (side-by-side) and / (stacked)\n'
    printf '# "claude" is replaced with the Claude command. Default: claude\n'
    printf '# panes: npm run dev | claude\n'
```

**Step 5: Verify syntax**

Run: `bash -n lib/core.sh`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add lib/core.sh
git commit -m "feat(config): add new CFG_* keys for lifecycle hooks, file ops, panes, dashboard"
```

---

## Task 2: Add global config loading to core.sh

**Files:**
- Modify: `lib/core.sh` (add `_load_global_config()` function, add `CLAUDEMIX_GLOBAL_CONFIG` constant)

**Step 1: Add global config constant**

Add after line 15 (`readonly CLAUDEMIX_TMUX_PREFIX="claudemix-"`):

```bash
readonly CLAUDEMIX_GLOBAL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claudemix"
readonly CLAUDEMIX_GLOBAL_CONFIG="${CLAUDEMIX_GLOBAL_CONFIG_DIR}/config.yaml"
```

**Step 2: Add _load_global_config() function**

Add before `load_config()` (before line 113):

```bash
# Load global user config from ~/.config/claudemix/config.yaml.
# Sets CFG_* defaults that project config can override.
_load_global_config() {
  if [[ ! -f "$CLAUDEMIX_GLOBAL_CONFIG" ]]; then
    log_debug "No global config found at $CLAUDEMIX_GLOBAL_CONFIG"
    return 0
  fi

  log_debug "Loading global config from $CLAUDEMIX_GLOBAL_CONFIG"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"

      case "$key" in
        validate)            CFG_VALIDATE="$value" ;;
        protected_branches)  CFG_PROTECTED_BRANCHES="$value" ;;
        merge_target)        CFG_MERGE_TARGET="$value" ;;
        merge_strategy)      CFG_MERGE_STRATEGY="$value" ;;
        claude_flags)        CFG_CLAUDE_FLAGS="$value" ;;
        base_branch)         CFG_BASE_BRANCH="$value" ;;
        worktree_dir)        CFG_WORKTREE_DIR="$value" ;;
        post_create)         CFG_POST_CREATE="$value" ;;
        pre_merge)           CFG_PRE_MERGE="$value" ;;
        pre_remove)          CFG_PRE_REMOVE="$value" ;;
        copy_files)          CFG_COPY_FILES="$value" ;;
        symlink_files)       CFG_SYMLINK_FILES="$value" ;;
        panes)               CFG_PANES="$value" ;;
        editor)              CFG_EDITOR="$value" ;;
        dashboard_refresh)   CFG_DASHBOARD_REFRESH="$value" ;;
        *)                   log_debug "Unknown global config key: $key" ;;
      esac
    fi
  done < "$CLAUDEMIX_GLOBAL_CONFIG"
}
```

**Step 3: Update load_config() to call _load_global_config() first**

Change `load_config()` so it calls `_load_global_config` at the top, before reading the project config. The project config values will then override the global ones:

Add as first line inside `load_config()`:

```bash
  _load_global_config
```

**Step 4: Add write_global_config() function**

Add after `write_default_config()`:

```bash
# Write global config with defaults.
write_global_config() {
  mkdir -p "$CLAUDEMIX_GLOBAL_CONFIG_DIR"
  {
    printf '# ClaudeMix global configuration\n'
    printf '# Personal defaults — project .claudemix.yml overrides these.\n'
    printf '# https://github.com/Draidel/ClaudeMix\n\n'
    printf '# editor: vim\n'
    printf '# dashboard_refresh: 2\n'
    printf '# claude_flags: --dangerously-skip-permissions\n'
    printf '# merge_strategy: squash\n'
    printf '# panes: claude\n'
  } > "$CLAUDEMIX_GLOBAL_CONFIG"
}
```

**Step 5: Verify syntax**

Run: `bash -n lib/core.sh`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add lib/core.sh
git commit -m "feat(config): add global config loading from ~/.config/claudemix/config.yaml"
```

---

## Task 3: Add lifecycle hooks and file operations to worktree.sh

**Files:**
- Modify: `lib/worktree.sh:11-48` (worktree_create — add hook + file ops calls)
- Modify: `lib/worktree.sh:52-101` (worktree_remove — add pre_remove hook)
- Modify: `lib/worktree.sh:188-207` (internal helpers — add new functions)

**Step 1: Add _run_lifecycle_hook() function**

Add at the end of `lib/worktree.sh` (after `_worktree_install_deps`):

```bash
# Run a lifecycle hook (script file or config command).
# Args: $1 = hook name (post_create, pre_merge, pre_remove)
#        $2 = session name
#        $3 = worktree path
# Returns: 0 on success or no hook, 1 on failure (only pre_merge blocks)
_run_lifecycle_hook() {
  local hook_name="$1"
  local name="$2"
  local wt_path="$3"
  local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"

  # Export environment variables for hooks
  local -x CLAUDEMIX_NAME="$name"
  local -x CLAUDEMIX_WORKTREE_PATH="$wt_path"
  local -x CLAUDEMIX_PROJECT_ROOT="$PROJECT_ROOT"
  local -x CLAUDEMIX_BRANCH="$branch"
  local -x CLAUDEMIX_BASE_BRANCH="$CFG_BASE_BRANCH"

  # Priority 1: script file in .claudemix/hooks/
  local hook_script="$PROJECT_ROOT/$CLAUDEMIX_DIR/hooks/$hook_name"
  if [[ -x "$hook_script" ]]; then
    log_info "Running hook ${CYAN}$hook_name${RESET} (script)"
    if (cd "$wt_path" && "$hook_script"); then
      log_ok "Hook $hook_name completed"
      return 0
    else
      log_warn "Hook $hook_name failed (exit $?)"
      return 1
    fi
  fi

  # Priority 2: inline command from config
  local cfg_var="CFG_$(printf '%s' "$hook_name" | tr '[:lower:]' '[:upper:]')"
  local hook_cmd="${!cfg_var:-}"
  if [[ -n "$hook_cmd" ]]; then
    log_info "Running hook ${CYAN}$hook_name${RESET} (config)"
    if (cd "$wt_path" && bash -c "$hook_cmd"); then
      log_ok "Hook $hook_name completed"
      return 0
    else
      log_warn "Hook $hook_name failed (exit $?)"
      return 1
    fi
  fi

  log_debug "No $hook_name hook configured"
  return 0
}
```

**Step 2: Add _worktree_copy_files() function**

Add after `_run_lifecycle_hook`:

```bash
# Copy configured files from project root into a new worktree.
# Args: $1 = worktree path
_worktree_copy_files() {
  local wt_path="$1"

  if [[ -z "$CFG_COPY_FILES" ]]; then
    return 0
  fi

  log_info "Copying files into worktree..."
  local IFS=','
  for pattern in $CFG_COPY_FILES; do
    # Trim whitespace
    pattern="$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$pattern" ]] && continue

    # Safety: reject path traversal
    if [[ "$pattern" == *".."* ]] || [[ "$pattern" == /* ]]; then
      log_warn "Skipping unsafe copy pattern: $pattern"
      continue
    fi

    # Use bash globbing in project root
    local matched=false
    # shellcheck disable=SC2086 # Intentional glob expansion
    for src in "$PROJECT_ROOT"/$pattern; do
      [[ -e "$src" ]] || continue
      matched=true

      # Get relative path
      local rel_path="${src#"$PROJECT_ROOT"/}"
      local dest="$wt_path/$rel_path"

      # Skip if already exists (git put it there)
      if [[ -e "$dest" ]]; then
        log_debug "Skip copy (exists): $rel_path"
        continue
      fi

      # Create parent directory and copy
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest"
      log_debug "Copied: $rel_path"
    done

    if ! $matched; then
      log_debug "No files matched copy pattern: $pattern"
    fi
  done
}

# Symlink configured files from project root into a new worktree.
# Args: $1 = worktree path
_worktree_symlink_files() {
  local wt_path="$1"

  if [[ -z "$CFG_SYMLINK_FILES" ]]; then
    return 0
  fi

  log_info "Symlinking files into worktree..."
  local IFS=','
  for pattern in $CFG_SYMLINK_FILES; do
    pattern="$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$pattern" ]] && continue

    if [[ "$pattern" == *".."* ]] || [[ "$pattern" == /* ]]; then
      log_warn "Skipping unsafe symlink pattern: $pattern"
      continue
    fi

    # shellcheck disable=SC2086 # Intentional glob expansion
    for src in "$PROJECT_ROOT"/$pattern; do
      [[ -e "$src" ]] || continue

      local rel_path="${src#"$PROJECT_ROOT"/}"
      local dest="$wt_path/$rel_path"

      if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
        log_debug "Skip symlink (exists): $rel_path"
        continue
      fi

      # Resolve absolute path for symlink target
      local abs_src
      abs_src="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"

      mkdir -p "$(dirname "$dest")"
      ln -s "$abs_src" "$dest"
      log_debug "Symlinked: $rel_path -> $abs_src"
    done
  done
}
```

**Step 3: Wire hooks and file ops into worktree_create()**

In `worktree_create()`, replace lines 43-47 (after `WORKTREE_PATH="$worktree_path"` through `return 0`):

```bash
  # shellcheck disable=SC2034 # Read by session.sh after worktree_create
  WORKTREE_PATH="$worktree_path"
  log_ok "Worktree created at ${DIM}$worktree_path${RESET}"

  # Copy/symlink configured files
  _worktree_copy_files "$worktree_path"
  _worktree_symlink_files "$worktree_path"

  # Install dependencies (fast — package managers use shared stores)
  _worktree_install_deps "$worktree_path"

  # Run post_create lifecycle hook
  _run_lifecycle_hook "post_create" "$name" "$worktree_path" || true

  return 0
```

**Step 4: Wire pre_remove hook into worktree_remove()**

In `worktree_remove()`, add before `log_info "Removing worktree"` (before line 85):

```bash
  # Run pre_remove lifecycle hook
  _run_lifecycle_hook "pre_remove" "$name" "$worktree_path" || true

```

**Step 5: Verify syntax**

Run: `bash -n lib/worktree.sh`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add lib/worktree.sh
git commit -m "feat(worktree): add lifecycle hooks (post_create, pre_remove) and file copy/symlink"
```

---

## Task 4: Add pre_merge hook to merge-queue.sh

**Files:**
- Modify: `lib/merge-queue.sh:94-107` (merge loop — add pre_merge hook check)

**Step 1: Add pre_merge hook call**

In `merge_queue_run()`, add before the merge loop (before line 97 `for branch in "${selected[@]}"`) a hook check that runs once for the whole merge operation. Also add per-branch pre_merge inside the loop.

Add before the loop:

```bash
  # Run pre_merge lifecycle hook (blocks on failure)
  if [[ -n "$CFG_PRE_MERGE" ]] || [[ -x "$PROJECT_ROOT/$CLAUDEMIX_DIR/hooks/pre_merge" ]]; then
    log_info "Running pre-merge validation..."
    # Use PROJECT_ROOT as worktree path since we're on the merge branch
    if ! _run_lifecycle_hook "pre_merge" "merge-${timestamp}" "$PROJECT_ROOT"; then
      log_error "Pre-merge hook failed. Aborting merge."
      git -C "$PROJECT_ROOT" checkout "${original_branch:-$CFG_MERGE_TARGET}" --quiet 2>/dev/null || true
      git -C "$PROJECT_ROOT" branch -D "$merge_branch" 2>/dev/null || true
      trap - EXIT
      return 1
    fi
  fi

```

Note: `_run_lifecycle_hook` is defined in `worktree.sh` which is sourced before `merge-queue.sh`, so it's available.

**Step 2: Verify syntax**

Run: `bash -n lib/merge-queue.sh`
Expected: no output (clean parse)

**Step 3: Commit**

```bash
git add lib/merge-queue.sh
git commit -m "feat(merge): add pre_merge lifecycle hook that blocks on failure"
```

---

## Task 5: Add pane layout parsing and tmux multi-pane launch to session.sh

**Files:**
- Modify: `lib/session.sh:1-49` (session_create — add arg parsing)
- Modify: `lib/session.sh:214-237` (_session_launch_tmux — multi-pane support)
- Add new functions at end of `lib/session.sh`

**Step 1: Rewrite session_create() with arg parsing**

Replace `session_create()` entirely:

```bash
# Create a new session and launch Claude Code in it.
# Args: $1 = session name, remaining args = extra claude flags or --with-changes/--pr/--panes
session_create() {
  local name
  name="$(sanitize_name "$1")"
  shift

  # Parse ClaudeMix flags vs Claude flags
  local with_changes=false
  local pr_number=""
  local panes_override=""
  local -a extra_flags=()
  while (( $# > 0 )); do
    case "$1" in
      --with-changes)
        with_changes=true
        ;;
      --pr)
        shift
        pr_number="${1:-}"
        [[ -z "$pr_number" ]] && die "Usage: claudemix <name> --pr <number>"
        ;;
      --pr=*)
        pr_number="${1#--pr=}"
        ;;
      --panes)
        shift
        panes_override="${1:-}"
        ;;
      --panes=*)
        panes_override="${1#--panes=}"
        ;;
      *)
        extra_flags+=("$1")
        ;;
    esac
    shift
  done

  ensure_claudemix_dir

  # Attach if already running
  if _session_is_running "$name"; then
    log_info "Session ${CYAN}$name${RESET} is already running. Attaching..."
    session_attach "$name"
    return $?
  fi

  # Handle --with-changes: stash uncommitted work
  local stashed=false
  if $with_changes; then
    if git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null && git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
      log_warn "No uncommitted changes to move."
    else
      log_info "Stashing uncommitted changes..."
      git -C "$PROJECT_ROOT" stash push -u -m "claudemix: moving to $name" || die "Failed to stash changes"
      stashed=true
    fi
  fi

  # Handle --pr: checkout PR branch
  if [[ -n "$pr_number" ]]; then
    if ! has_cmd gh; then
      die "GitHub CLI (gh) required for --pr. Install: brew install gh"
    fi
    local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
    log_info "Checking out PR #${pr_number} as ${CYAN}$branch${RESET}..."
    gh pr checkout "$pr_number" --branch "$branch" 2>/dev/null || die "Failed to checkout PR #$pr_number"
  fi

  # Create isolated worktree
  worktree_create "$name"
  local wt_path="$WORKTREE_PATH"

  # Handle --with-changes: pop stash in new worktree
  if $stashed; then
    log_info "Applying stashed changes to worktree..."
    if ! (cd "$wt_path" && git stash pop 2>/dev/null); then
      log_warn "Stash apply had conflicts. Resolve them in the worktree."
    else
      log_ok "Uncommitted changes moved to worktree"
    fi
  fi

  # Build claude command as an array (safe — no eval)
  local -a claude_cmd=(claude)
  if [[ -n "$CFG_CLAUDE_FLAGS" ]]; then
    local -a flags
    read -ra flags <<< "$CFG_CLAUDE_FLAGS"
    claude_cmd+=("${flags[@]}")
  fi
  if (( ${#extra_flags[@]} > 0 )); then
    claude_cmd+=("${extra_flags[@]}")
  fi

  # Determine pane layout
  local panes="${panes_override:-$CFG_PANES}"

  # Persist session metadata
  _session_save_meta "$name" "$wt_path" "$panes"

  # Launch in tmux (persistent) or foreground (ephemeral)
  if tmux_available; then
    _session_launch_tmux "$name" "$wt_path" "$panes" "${claude_cmd[@]}"
  else
    if [[ -n "$panes" ]] && [[ "$panes" != "claude" ]]; then
      log_warn "Pane layouts require tmux. Only Claude will run."
    fi
    _session_launch_direct "$name" "$wt_path" "${claude_cmd[@]}"
  fi
}
```

**Step 2: Add _parse_panes() function**

Add at end of `lib/session.sh`:

```bash
# Parse a pane layout string into structured output.
# Syntax: "cmd1 / cmd2 | cmd3" means cmd1 stacked over cmd2, side-by-side with cmd3
# | = vertical split (columns, tmux split-window -h)
# / = horizontal split (rows, tmux split-window -v)
# Output: one line per pane: "direction\tcommand"
#   First pane has direction "first" (it's the initial pane).
# Args: $1 = pane layout string, $2+ = claude command array
_parse_panes() {
  local layout="$1"
  shift
  local -a claude_cmd=("$@")

  # Build safe claude command string
  local safe_claude=""
  for arg in "${claude_cmd[@]}"; do
    safe_claude+="$(printf '%q ' "$arg")"
  done
  safe_claude="${safe_claude% }"

  # Default: just claude
  if [[ -z "$layout" ]] || [[ "$layout" == "claude" ]]; then
    printf 'first\t%s\n' "$safe_claude"
    return 0
  fi

  local first=true

  # Split by | first (vertical/column splits)
  local IFS='|'
  local -a columns
  read -ra columns <<< "$layout"

  for col in "${columns[@]}"; do
    # Trim whitespace
    col="$(printf '%s' "$col" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$col" ]] && continue

    # Split by / (horizontal/row splits within this column)
    local old_ifs="$IFS"
    IFS='/'
    local -a rows
    read -ra rows <<< "$col"
    IFS="$old_ifs"

    for row in "${rows[@]}"; do
      row="$(printf '%s' "$row" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$row" ]] && continue

      # Replace "claude" keyword with actual command
      local cmd="$row"
      if [[ "$cmd" == "claude" ]]; then
        cmd="$safe_claude"
      fi

      if $first; then
        printf 'first\t%s\n' "$cmd"
        first=false
      else
        # Determine split direction based on context:
        # If this row is within a column that has multiple rows, it's horizontal (v)
        # Otherwise it's a new column, so vertical (h)
        if (( ${#rows[@]} > 1 )); then
          printf 'v\t%s\n' "$cmd"
        else
          printf 'h\t%s\n' "$cmd"
        fi
      fi
    done
  done
}
```

**Step 3: Rewrite _session_launch_tmux() with pane support**

Replace the entire `_session_launch_tmux` function:

```bash
# Launch session in tmux with optional pane layout.
# Args: $1 = name, $2 = worktree path, $3 = pane layout string, $4+ = claude command array
_session_launch_tmux() {
  local name="$1"
  local wt_path="$2"
  local panes="$3"
  shift 3
  local -a claude_cmd=("$@")
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  log_info "Launching session ${CYAN}$tmux_name${RESET} in tmux"

  # Parse pane layout
  local -a pane_dirs=()
  local -a pane_cmds=()
  local claude_pane_idx=0
  local pane_idx=0

  while IFS=$'\t' read -r direction cmd; do
    pane_dirs+=("$direction")
    # Add exit prompt to each pane command
    pane_cmds+=("${cmd}; printf '\\nProcess exited. Press Enter to close.\\n'; read")
    # Track which pane has claude
    local safe_claude=""
    for arg in "${claude_cmd[@]}"; do
      safe_claude+="$(printf '%q ' "$arg")"
    done
    safe_claude="${safe_claude% }"
    if [[ "$cmd" == "$safe_claude" ]]; then
      claude_pane_idx=$pane_idx
    fi
    pane_idx=$((pane_idx + 1))
  done < <(_parse_panes "$panes" "${claude_cmd[@]}")

  # Create session with first pane
  if in_tmux; then
    tmux new-session -d -s "$tmux_name" -c "$wt_path" "${pane_cmds[0]}"
  else
    tmux new-session -d -s "$tmux_name" -c "$wt_path" "${pane_cmds[0]}"
  fi

  # Add remaining panes
  local i=1
  while (( i < ${#pane_cmds[@]} )); do
    local split_flag="-h"
    [[ "${pane_dirs[$i]}" == "v" ]] && split_flag="-v"
    tmux split-window $split_flag -t "$tmux_name" -c "$wt_path" "${pane_cmds[$i]}"
    i=$((i + 1))
  done

  # Balance pane sizes
  if (( ${#pane_cmds[@]} > 1 )); then
    tmux select-layout -t "$tmux_name" tiled 2>/dev/null || true
  fi

  # Select the claude pane
  tmux select-pane -t "${tmux_name}:.${claude_pane_idx}" 2>/dev/null || true

  # Attach
  if in_tmux; then
    tmux switch-client -t "=$tmux_name"
  else
    tmux attach-session -t "=$tmux_name"
  fi
}
```

**Step 4: Update _session_save_meta() to store panes**

Replace `_session_save_meta`:

```bash
# Persist session metadata.
# Args: $1 = name, $2 = worktree path, $3 = panes layout (optional)
_session_save_meta() {
  local name="$1"
  local wt_path="$2"
  local panes="${3:-}"
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"

  {
    printf 'name=%s\n' "$name"
    printf 'created_at=%s\n' "$(now_iso)"
    printf 'branch=%s\n' "${CLAUDEMIX_BRANCH_PREFIX}${name}"
    printf 'worktree=%s\n' "$wt_path"
    printf 'tmux_session=%s\n' "${CLAUDEMIX_TMUX_PREFIX}${name}"
    printf 'base_branch=%s\n' "$CFG_BASE_BRANCH"
    printf 'status=open\n'
    printf 'panes=%s\n' "$panes"
  } > "$meta_file"
}
```

**Step 5: Verify syntax**

Run: `bash -n lib/session.sh`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add lib/session.sh
git commit -m "feat(session): add pane layouts, --with-changes, --pr flags, arg parsing"
```

---

## Task 6: Add session_open() and session_close() to session.sh

**Files:**
- Modify: `lib/session.sh` (add two new functions, update session_list)

**Step 1: Add session_close()**

Add after `session_attach()`:

```bash
# Close a session (kill tmux, keep worktree and branch).
# Args: $1 = session name
session_close() {
  local name
  name="$(sanitize_name "$1")"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  if ! worktree_exists "$name"; then
    die "Session '$name' not found (no worktree)."
  fi

  # Kill tmux session
  if tmux_available && tmux has-session -t "=$tmux_name" 2>/dev/null; then
    tmux kill-session -t "=$tmux_name" 2>/dev/null || true
    log_ok "tmux session ${CYAN}$tmux_name${RESET} closed"
  else
    log_info "Session ${CYAN}$name${RESET} has no running tmux session"
  fi

  # Update metadata
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"
  if [[ -f "$meta_file" ]]; then
    # Update status to closed (use sed for in-place update)
    if grep -q '^status=' "$meta_file" 2>/dev/null; then
      sed -i.bak 's/^status=.*/status=closed/' "$meta_file" && rm -f "${meta_file}.bak"
    else
      printf 'status=closed\n' >> "$meta_file"
    fi
  fi

  log_ok "Session ${CYAN}$name${RESET} closed (worktree and branch preserved)"
}
```

**Step 2: Add session_open()**

Add after `session_close()`:

```bash
# Reopen a closed session (rebuild tmux, relaunch panes).
# Args: $1 = session name
session_open() {
  local name
  name="$(sanitize_name "$1")"

  if ! worktree_exists "$name"; then
    die "Session '$name' not found. Create it with: claudemix $name"
  fi

  # If already running, just attach
  if _session_is_running "$name"; then
    log_info "Session ${CYAN}$name${RESET} is already running. Attaching..."
    session_attach "$name"
    return $?
  fi

  local wt_path
  wt_path="$(worktree_path "$name")"

  # Read pane layout from metadata
  local panes=""
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"
  if [[ -f "$meta_file" ]]; then
    panes="$(grep '^panes=' "$meta_file" 2>/dev/null | cut -d= -f2- || echo "")"
  fi
  panes="${panes:-$CFG_PANES}"

  # Build claude command
  local -a claude_cmd=(claude)
  if [[ -n "$CFG_CLAUDE_FLAGS" ]]; then
    local -a flags
    read -ra flags <<< "$CFG_CLAUDE_FLAGS"
    claude_cmd+=("${flags[@]}")
  fi

  # Update metadata
  if [[ -f "$meta_file" ]]; then
    if grep -q '^status=' "$meta_file" 2>/dev/null; then
      sed -i.bak 's/^status=.*/status=open/' "$meta_file" && rm -f "${meta_file}.bak"
    else
      printf 'status=open\n' >> "$meta_file"
    fi
  fi

  # Launch
  if tmux_available; then
    _session_launch_tmux "$name" "$wt_path" "$panes" "${claude_cmd[@]}"
  else
    _session_launch_direct "$name" "$wt_path" "${claude_cmd[@]}"
  fi
}
```

**Step 3: Update session_list() to show pane count and closed status**

Replace the status detection logic in `session_list()`. Change the inner loop body (where `tmux_status` is set) to also detect pane count and closed status:

Replace lines that set `tmux_status="stopped"` through `tmux_status="running"` with:

```bash
    # Check tmux status and pane count
    if tmux_available && tmux has-session -t "=$tmux_name" 2>/dev/null; then
      tmux_status="running"
    else
      # Check metadata for closed vs stopped
      local meta_status
      meta_status="$(grep '^status=' "$meta_file" 2>/dev/null | cut -d= -f2- || echo "")"
      if [[ "$meta_status" == "closed" ]]; then
        tmux_status="closed"
      fi
    fi

    # Get pane count from tmux and metadata
    local pane_info=""
    local total_panes=0
    local running_panes=0
    if [[ "$tmux_status" == "running" ]]; then
      running_panes="$(tmux list-panes -t "=$tmux_name" 2>/dev/null | wc -l | tr -d '[:space:]')"
    fi
    # Read total from metadata panes config
    local meta_panes
    meta_panes="$(grep '^panes=' "$meta_file" 2>/dev/null | cut -d= -f2- || echo "")"
    if [[ -n "$meta_panes" ]] && [[ "$meta_panes" != "claude" ]]; then
      # Count panes in layout: count separators + 1
      local sep_count=0
      local tmp="$meta_panes"
      tmp="${tmp//[!|\/]/}"
      sep_count=${#tmp}
      total_panes=$((sep_count + 1))
    else
      total_panes=1
    fi
    pane_info="${running_panes}/${total_panes}"
```

Update the table header format to include PANES column, and add `$pane_info` to session data.

Update the `sessions+=` line to include pane info:

```bash
    sessions+=("$wt_name|$wt_branch|$tmux_status|$pane_info|$wt_status|$created_at")
```

Update the table header and row format in the `table` case:

```bash
    table)
      printf "${BOLD}%-20s %-30s %-10s %-7s %-20s %s${RESET}\n" "NAME" "BRANCH" "STATUS" "PANES" "GIT" "CREATED"
      printf "%-20s %-30s %-10s %-7s %-20s %s\n" "────" "──────" "──────" "─────" "───" "───────"
      for entry in "${sessions[@]}"; do
        IFS='|' read -r s_name s_branch s_status s_panes s_git s_created <<< "$entry"
        local status_color="$RED"
        [[ "$s_status" == "running" ]] && status_color="$GREEN"
        [[ "$s_status" == "closed" ]] && status_color="$YELLOW"
        local created_display=""
        if [[ -n "$s_created" ]]; then
          created_display="$(format_time "$s_created")"
        fi
        printf "%-20s %-30s ${status_color}%-10s${RESET} %-7s %-20s %s\n" \
          "$s_name" "$s_branch" "$s_status" "$s_panes" "$s_git" "$created_display"
      done
```

**Step 4: Verify syntax**

Run: `bash -n lib/session.sh`
Expected: no output (clean parse)

**Step 5: Commit**

```bash
git add lib/session.sh
git commit -m "feat(session): add open/close commands and pane count in session list"
```

---

## Task 7: Create lib/dashboard.sh

**Files:**
- Create: `lib/dashboard.sh`

**Step 1: Write the dashboard module**

```bash
# shellcheck shell=bash
# ClaudeMix — dashboard.sh
# Live dashboard for monitoring active sessions and their panes.
# Sourced by bin/claudemix. Never executed directly.

# ── Dashboard Operations ───────────────────────────────────────────────────

# Run the live dashboard with auto-refresh.
dashboard_run() {
  if ! tmux_available; then
    die "Dashboard requires tmux."
  fi

  local refresh="${CFG_DASHBOARD_REFRESH:-2}"
  log_info "Starting dashboard (refresh: ${refresh}s, press 'q' to quit)"

  while true; do
    # Clear screen (portable)
    printf '\033[2J\033[H'

    # Header
    printf "${BOLD}ClaudeMix Dashboard${RESET} — %s  ${DIM}(refresh: %ds, q to quit)${RESET}\n\n" \
      "$(date '+%H:%M:%S')" "$refresh"

    # Session table
    session_list "table"

    # Pane details for running sessions
    printf '\n'
    _dashboard_show_panes

    # Wait for input or timeout
    if read -t "$refresh" -n1 key 2>/dev/null; then
      case "${key:-}" in
        q|Q) printf '\n'; return 0 ;;
      esac
    fi
  done
}

# ── Internal Helpers ─────────────────────────────────────────────────────

# Show per-session pane details.
_dashboard_show_panes() {
  local found=false

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

    if ! tmux has-session -t "=$tmux_name" 2>/dev/null; then
      continue
    fi

    found=true
    printf "${BOLD}%s${RESET}:\n" "$name"

    local pane_idx=0
    while IFS=$'\t' read -r pane_pid pane_cmd pane_active; do
      [[ -z "$pane_pid" ]] && continue
      pane_idx=$((pane_idx + 1))

      # Determine if pane process is alive
      local status_icon="${GREEN}●${RESET}"
      if ! kill -0 "$pane_pid" 2>/dev/null; then
        status_icon="${RED}●${RESET}"
      fi

      local active_marker=""
      [[ "$pane_active" == "1" ]] && active_marker=" ${CYAN}*${RESET}"

      printf "  [%d] %-30s %b%s\n" "$pane_idx" "$pane_cmd" "$status_icon" "$active_marker"
    done < <(tmux list-panes -t "=$tmux_name" -F '#{pane_pid}	#{pane_current_command}	#{pane_active}' 2>/dev/null)

    printf '\n'
  done < <(session_list "names")

  if ! $found; then
    printf "  ${DIM}No running sessions to show pane details for.${RESET}\n"
  fi
}
```

**Step 2: Verify syntax**

Run: `bash -n lib/dashboard.sh`
Expected: no output (clean parse)

**Step 3: Commit**

```bash
git add lib/dashboard.sh
git commit -m "feat: add live dashboard module (lib/dashboard.sh)"
```

---

## Task 8: Update bin/claudemix — routing, sourcing, help

**Files:**
- Modify: `bin/claudemix`

**Step 1: Add dashboard.sh source**

Add after the tui.sh source line (`source "$CLAUDEMIX_HOME/lib/tui.sh"`):

```bash
# shellcheck source=lib/dashboard.sh
source "$CLAUDEMIX_HOME/lib/dashboard.sh"
```

**Step 2: Add new command cases in main()**

Add new cases in the `case "$command" in` block, before the `*)` catch-all:

```bash
    open)
      shift
      if [[ -n "${1:-}" ]]; then
        session_open "$1"
      else
        die "Usage: claudemix open <session-name>"
      fi
      ;;
    close)
      shift
      if [[ -n "${1:-}" ]]; then
        session_close "$1"
      else
        die "Usage: claudemix close <session-name>"
      fi
      ;;
    dashboard|dash)
      dashboard_run
      ;;
    config)
      shift
      case "${1:-show}" in
        edit)
          "${CFG_EDITOR:-vim}" "$CLAUDEMIX_GLOBAL_CONFIG"
          ;;
        show)
          _show_config
          ;;
        init)
          write_global_config
          log_ok "Global config written to $CLAUDEMIX_GLOBAL_CONFIG"
          ;;
        *)
          die "Usage: claudemix config [show|edit|init]"
          ;;
      esac
      ;;
```

**Step 3: Add _show_config() helper function**

Add before `main()` in `bin/claudemix`:

```bash
_show_config() {
  printf "${BOLD}ClaudeMix Configuration${RESET}\n\n"
  printf "${DIM}Global:${RESET}  %s\n" "$CLAUDEMIX_GLOBAL_CONFIG"
  printf "${DIM}Project:${RESET} %s\n\n" "$PROJECT_ROOT/$CLAUDEMIX_CONFIG_FILE"

  printf "%-22s %s\n" "Key" "Value"
  printf "%-22s %s\n" "───" "─────"
  printf "%-22s %s\n" "validate" "${CFG_VALIDATE:-(auto-detected)}"
  printf "%-22s %s\n" "protected_branches" "$CFG_PROTECTED_BRANCHES"
  printf "%-22s %s\n" "merge_target" "$CFG_MERGE_TARGET"
  printf "%-22s %s\n" "merge_strategy" "$CFG_MERGE_STRATEGY"
  printf "%-22s %s\n" "base_branch" "$CFG_BASE_BRANCH"
  printf "%-22s %s\n" "claude_flags" "$CFG_CLAUDE_FLAGS"
  printf "%-22s %s\n" "worktree_dir" "$CFG_WORKTREE_DIR"
  printf "%-22s %s\n" "post_create" "${CFG_POST_CREATE:-(none)}"
  printf "%-22s %s\n" "pre_merge" "${CFG_PRE_MERGE:-(none)}"
  printf "%-22s %s\n" "pre_remove" "${CFG_PRE_REMOVE:-(none)}"
  printf "%-22s %s\n" "copy_files" "${CFG_COPY_FILES:-(none)}"
  printf "%-22s %s\n" "symlink_files" "${CFG_SYMLINK_FILES:-(none)}"
  printf "%-22s %s\n" "panes" "${CFG_PANES:-(default: claude)}"
  printf "%-22s %s\n" "editor" "$CFG_EDITOR"
  printf "%-22s %s\n" "dashboard_refresh" "${CFG_DASHBOARD_REFRESH}s"
}
```

**Step 4: Update _show_help()**

Replace the entire help text:

```
ClaudeMix — Multi-session orchestrator for Claude Code

USAGE
  claudemix                         Interactive TUI menu
  claudemix <name>                  Create or attach to a named session
  claudemix <name> [claude-flags]   Create session with extra Claude flags
  claudemix <name> --with-changes   Move uncommitted work into new session
  claudemix <name> --pr <number>    Create session from a GitHub PR
  claudemix <name> --panes "layout" Override pane layout for this session
  claudemix open <name>             Reopen a closed session
  claudemix close <name>            Close session (keep worktree/branch)
  claudemix ls                      List active sessions
  claudemix kill <name|all>         Kill a session and remove worktree
  claudemix merge                   Consolidate branches into a single PR
  claudemix merge list              Show branches eligible for merge
  claudemix cleanup                 Remove worktrees for merged branches
  claudemix dashboard               Live session monitoring dashboard
  claudemix hooks install           Install pre-commit + pre-push hooks
  claudemix hooks uninstall         Remove ClaudeMix hooks
  claudemix hooks status            Show current hook status
  claudemix config show             Show merged configuration
  claudemix config edit             Edit global config in $EDITOR
  claudemix config init             Create global config with defaults
  claudemix init                    Generate .claudemix.yml config
  claudemix version                 Show version
  claudemix help                    Show this help

PANE LAYOUTS
  Define pane layouts in .claudemix.yml or with --panes flag.
  | = side-by-side split    / = stacked split    claude = Claude pane

  Examples:
    panes: claude                        Single Claude pane (default)
    panes: "npm run dev | claude"        Dev server left, Claude right
    panes: "npm run dev / tests | claude" Dev + tests left, Claude right

SESSION LIFECYCLE
  1. claudemix <name>     Creates worktree + tmux session + launches panes
  2. Claude works          In an isolated branch (claudemix/<name>)
  3. claudemix close <name> Close tmux, keep worktree for later
  4. claudemix open <name>  Reopen and resume where you left off
  5. claudemix merge       Consolidate branches into a single PR
  6. claudemix cleanup     Remove merged worktrees

LIFECYCLE HOOKS
  Configure in .claudemix.yml or as scripts in .claudemix/hooks/:
    post_create   Runs after worktree creation (e.g., copy .env, run migrations)
    pre_merge     Runs before merge (blocks on failure)
    pre_remove    Runs before worktree removal

CONFIGURATION
  Global:  ~/.config/claudemix/config.yaml (personal defaults)
  Project: .claudemix.yml (overrides global)
  Run 'claudemix init' to generate project config.
  Run 'claudemix config init' for global config.

DEPENDENCIES
  Required: git, claude (Claude Code CLI)
  Optional: tmux (panes/persistence), gum (TUI), gh (PRs), node (husky hooks)

ENVIRONMENT VARIABLES
  CLAUDEMIX_DEBUG=1     Enable debug logging
  CLAUDEMIX_HOME=...    Override installation directory
  NO_COLOR=1            Disable colored output
```

**Step 5: Verify syntax**

Run: `bash -n bin/claudemix`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add bin/claudemix
git commit -m "feat(cli): add open, close, dashboard, config commands and updated help"
```

---

## Task 9: Update TUI with new menu items

**Files:**
- Modify: `lib/tui.sh`

**Step 1: Add new menu actions to _tui_choose_action()**

Update the gum choice list and fallback menu to include: Open session, Close session, Dashboard, and Global config. Update the `while true` loop in `tui_main_menu()` to handle the new actions.

In `tui_main_menu()`, add new cases:

```bash
      open)      _tui_open_session ;;
      close)     _tui_close_session ;;
      dashboard) dashboard_run ;;
      config)    _tui_config_menu ;;
```

In the gum menu, add items:

```
      "Open session" \
      "Close session" \
```
(after "Attach to session")

Add:
```
      "Dashboard" \
```
(after "Kill session")

Add:
```
      "Global config" \
```
(after "Init config")

Update case mapping for gum choices:

```bash
      "Open session")       printf 'open' ;;
      "Close session")      printf 'close' ;;
      "Dashboard")          printf 'dashboard' ;;
      "Global config")      printf 'config' ;;
```

Update fallback numbered menu (renumber everything):

```
    printf '  1) New session\n'
    printf '  2) Attach to session\n'
    printf '  3) Open session\n'
    printf '  4) Close session\n'
    printf '  5) List sessions\n'
    printf '  6) Merge queue\n'
    printf '  7) Cleanup merged\n'
    printf '  8) Kill session\n'
    printf '  9) Dashboard\n'
    printf ' 10) Git hooks\n'
    printf ' 11) Init config\n'
    printf ' 12) Global config\n'
    printf ' 13) Quit\n\n'
```

**Step 2: Add _tui_open_session()**

```bash
_tui_open_session() {
  # Show only closed/stopped sessions
  local -a names=()
  while IFS='|' read -r s_name s_branch s_status _rest; do
    [[ -z "$s_name" ]] && continue
    [[ "$s_status" == "running" ]] && continue
    names+=("$s_name")
  done < <(session_list "raw")

  if (( ${#names[@]} == 0 )); then
    log_info "No closed sessions to open."
    _tui_pause
    return 0
  fi

  local selected
  if gum_available; then
    selected="$(printf '%s\n' "${names[@]}" | gum choose --header "Open session")" || return 0
  else
    printf 'Closed sessions:\n'
    local idx=1
    for n in "${names[@]}"; do
      printf '  %d) %s\n' "$idx" "$n"
      idx=$((idx + 1))
    done
    printf 'Choose: '
    read -r num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#names[@]} )); then
      selected="${names[$((num-1))]}"
    fi
  fi

  if [[ -n "${selected:-}" ]]; then
    session_open "$selected"
  fi
}
```

**Step 3: Add _tui_close_session()**

```bash
_tui_close_session() {
  # Show only running sessions
  local -a names=()
  while IFS='|' read -r s_name s_branch s_status _rest; do
    [[ -z "$s_name" ]] && continue
    [[ "$s_status" != "running" ]] && continue
    names+=("$s_name")
  done < <(session_list "raw")

  if (( ${#names[@]} == 0 )); then
    log_info "No running sessions to close."
    _tui_pause
    return 0
  fi

  local selected
  if gum_available; then
    selected="$(printf '%s\n' "${names[@]}" | gum choose --header "Close session")" || return 0
  else
    printf 'Running sessions:\n'
    local idx=1
    for n in "${names[@]}"; do
      printf '  %d) %s\n' "$idx" "$n"
      idx=$((idx + 1))
    done
    printf 'Choose: '
    read -r num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#names[@]} )); then
      selected="${names[$((num-1))]}"
    fi
  fi

  if [[ -n "${selected:-}" ]]; then
    session_close "$selected"
  fi

  _tui_pause
}
```

**Step 4: Add _tui_config_menu()**

```bash
_tui_config_menu() {
  local action
  if gum_available; then
    action="$(gum choose \
      --header "Global Config" \
      "Show merged config" \
      "Edit global config" \
      "Create global config" \
      "Back" \
    )" || return 0
  else
    printf '\n  1) Show merged config\n  2) Edit global config\n  3) Create global config\n  4) Back\nChoose: '
    read -r num
    case "$num" in
      1) action="Show merged config" ;;
      2) action="Edit global config" ;;
      3) action="Create global config" ;;
      *) return 0 ;;
    esac
  fi

  case "$action" in
    "Show merged config")   _show_config; _tui_pause ;;
    "Edit global config")   "${CFG_EDITOR:-vim}" "$CLAUDEMIX_GLOBAL_CONFIG" ;;
    "Create global config") write_global_config; log_ok "Global config written to $CLAUDEMIX_GLOBAL_CONFIG"; _tui_pause ;;
    "Back")                 return 0 ;;
  esac
}
```

**Step 5: Verify syntax**

Run: `bash -n lib/tui.sh`
Expected: no output (clean parse)

**Step 6: Commit**

```bash
git add lib/tui.sh
git commit -m "feat(tui): add open, close, dashboard, and global config menu items"
```

---

## Task 10: Update .claudemix.yml.example

**Files:**
- Modify: `.claudemix.yml.example`

**Step 1: Update the example config**

```yaml
# ClaudeMix configuration
# Drop this file as .claudemix.yml in your project root.
# All values are optional — ClaudeMix auto-detects sensible defaults.
# Global defaults: ~/.config/claudemix/config.yaml
# https://github.com/Draidel/ClaudeMix

# Command to validate code before push.
# Auto-detected from package.json, Makefile, Cargo.toml, or go.mod.
validate: pnpm validate

# Branches that cannot be pushed to directly (comma-separated).
# Pre-push hook blocks pushes to these branches.
protected_branches: main,staging

# Target branch for merge queue PRs.
merge_target: staging

# Merge strategy for PRs: squash, merge, or rebase.
merge_strategy: squash

# Base branch for new worktrees.
# New sessions branch off from this.
base_branch: staging

# Directory for worktrees (relative to project root).
# Default: .claudemix/worktrees
worktree_dir: .claudemix/worktrees

# Extra flags to pass to Claude Code on every session launch.
claude_flags: --dangerously-skip-permissions --verbose

# Lifecycle hooks (run during worktree operations).
# Also supports script files in .claudemix/hooks/ (takes precedence).
# post_create: cp .env.example .env && pnpm install
# pre_merge: pnpm test
# pre_remove: echo cleaning up

# Files to copy into new worktrees (comma-separated globs).
# Useful for environment files not tracked by git.
# copy_files: .env,.env.local,.env.development

# Files/directories to symlink into new worktrees (comma-separated).
# Useful for large dependencies like node_modules.
# symlink_files: node_modules

# Pane layout: commands separated by | (side-by-side) and / (stacked).
# "claude" is replaced with the Claude command. Default: claude only.
# panes: npm run dev | claude
# panes: npm run dev / pnpm test --watch | claude
```

**Step 2: Commit**

```bash
git add .claudemix.yml.example
git commit -m "docs: update .claudemix.yml.example with new config keys"
```

---

## Task 11: Update shell completions

**Files:**
- Modify: `completions/claudemix.zsh`
- Modify: `completions/claudemix.bash`
- Modify: `completions/claudemix.fish`

**Step 1: Update zsh completions**

Add new commands to the `commands` array:

```bash
  commands=(
    'ls:List active sessions'
    'list:List active sessions'
    'open:Reopen a closed session'
    'close:Close session (keep worktree)'
    'kill:Kill a session'
    'merge:Consolidate branches into a single PR'
    'cleanup:Remove worktrees for merged branches'
    'clean:Remove worktrees for merged branches'
    'dashboard:Live session monitoring'
    'dash:Live session monitoring'
    'hooks:Manage git hooks'
    'config:Manage configuration'
    'init:Generate .claudemix.yml config'
    'version:Show version'
    'help:Show help'
  )
```

Add config and dashboard subcommands:

```bash
  local -a config_subcommands
  config_subcommands=(
    'show:Show merged configuration'
    'edit:Edit global config'
    'init:Create global config'
  )
```

Add cases for open, close, config in the args section:

```bash
        open|close)
          local sessions
          sessions=($(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null))
          _describe 'session' sessions
          ;;
        config)
          _describe 'config subcommand' config_subcommands
          ;;
```

**Step 2: Update bash completions**

Update the commands string:

```bash
  commands="ls list open close kill merge cleanup clean dashboard dash hooks config init version help"
```

Add cases for open, close, config:

```bash
    open|close)
      local sessions
      sessions="$(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null)"
      COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
      ;;
    config)
      COMPREPLY=($(compgen -W "show edit init" -- "$cur"))
      ;;
```

**Step 3: Update fish completions**

Add new top-level commands:

```fish
complete -c claudemix -n "__fish_use_subcommand" -a "open" -d "Reopen a closed session"
complete -c claudemix -n "__fish_use_subcommand" -a "close" -d "Close session (keep worktree)"
complete -c claudemix -n "__fish_use_subcommand" -a "dashboard" -d "Live session monitoring"
complete -c claudemix -n "__fish_use_subcommand" -a "dash" -d "Live session monitoring"
complete -c claudemix -n "__fish_use_subcommand" -a "config" -d "Manage configuration"
```

Add subcommand completions:

```fish
# open/close subcommands: session names
complete -c claudemix -n "__fish_seen_subcommand_from open" -a "(__claudemix_sessions)" -d "Session"
complete -c claudemix -n "__fish_seen_subcommand_from close" -a "(__claudemix_sessions)" -d "Session"

# config subcommands
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "show" -d "Show merged configuration"
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "edit" -d "Edit global config"
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "init" -d "Create global config"
```

**Step 4: Verify no syntax issues**

Run: `bash -n completions/claudemix.bash`
Expected: no output

**Step 5: Commit**

```bash
git add completions/
git commit -m "feat(completions): add open, close, dashboard, config commands to all shells"
```

---

## Task 12: Syntax check all files and functional smoke test

**Step 1: Syntax check every script**

Run:
```bash
for f in bin/claudemix lib/*.sh install.sh; do bash -n "$f" && echo "$f OK"; done
```
Expected: all files print "OK"

**Step 2: Quick functional tests**

Run:
```bash
bash bin/claudemix version
bash bin/claudemix help
```
Expected: version prints, help shows all new commands

**Step 3: Test config show**

Run from a git project:
```bash
bash bin/claudemix config show
```
Expected: prints all config keys with values

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address issues found during smoke testing"
```

---

## Task 13: Update CLAUDE.md with new commands and patterns

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the Architecture section**

Add `lib/dashboard.sh` to the file listing:

```
lib/dashboard.sh    Live dashboard: session monitoring, pane status display
```

**Step 2: Update "Adding a new command" pattern**

Already covers the steps — no changes needed, but verify `dashboard.sh` is mentioned in the source chain.

**Step 3: Add "Adding a new config key" note about global config**

Add to the existing pattern:

```
6. If applicable, add to `write_global_config()` in `core.sh`
```

**Step 4: Update File Relationships**

Add dashboard.sh to the sourcing diagram:

```
                 lib/dashboard.sh (depends on core.sh, session.sh)
```

**Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with dashboard module and new commands"
```
