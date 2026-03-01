# shellcheck shell=bash
# ClaudeMix — worktree.sh
# Git worktree lifecycle: create, remove, list, cleanup.
# Sourced by bin/claudemix. Never executed directly.

# ── Worktree Operations ──────────────────────────────────────────────────────

# Create a new worktree for a session.
# Args: $1 = session name (sanitized)
# Sets: WORKTREE_PATH (global, absolute path to the created worktree)
worktree_create() {
  local name="$1"
  local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
  local worktree_path="$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"

  # Re-use existing worktree
  if [[ -d "$worktree_path" ]]; then
    log_debug "Worktree already exists: $worktree_path"
    WORKTREE_PATH="$worktree_path"
    return 0
  fi

  # Fetch latest base branch from remote if available
  log_info "Creating worktree ${CYAN}$name${RESET} from ${CYAN}$CFG_BASE_BRANCH${RESET}"
  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$CFG_BASE_BRANCH" 2>/dev/null; then
    git -C "$PROJECT_ROOT" fetch origin "$CFG_BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  # Create the branch + worktree
  if branch_exists "$branch"; then
    git -C "$PROJECT_ROOT" worktree add "$worktree_path" "$branch" 2>/dev/null || {
      die "Failed to create worktree. Branch '$branch' may already have a worktree."
    }
  else
    git -C "$PROJECT_ROOT" worktree add -b "$branch" "$worktree_path" "$CFG_BASE_BRANCH" 2>/dev/null || {
      die "Failed to create worktree from '$CFG_BASE_BRANCH'. Is the branch available?"
    }
  fi

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
}

# Remove a worktree and optionally its branch.
# Args: $1 = session name, $2 = "keep-branch" to preserve the branch
worktree_remove() {
  local name="$1"
  local keep_branch="${2:-}"
  local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
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

  # Run pre_remove lifecycle hook
  _run_lifecycle_hook "pre_remove" "$name" "$worktree_path" || true

  log_info "Removing worktree ${CYAN}$name${RESET}"
  git -C "$PROJECT_ROOT" worktree remove "$worktree_path" --force 2>/dev/null || {
    log_warn "git worktree remove failed, cleaning up manually"
    rm -rf "$worktree_path"
    git -C "$PROJECT_ROOT" worktree prune 2>/dev/null || true
  }

  if [[ "$keep_branch" != "keep-branch" ]]; then
    if branch_exists "$branch"; then
      git -C "$PROJECT_ROOT" branch -D "$branch" 2>/dev/null || {
        log_warn "Could not delete branch $branch (may have unmerged changes)"
      }
    fi
  fi

  log_ok "Worktree ${CYAN}$name${RESET} removed"
}

# List all ClaudeMix worktrees with status.
# Output: tab-separated lines: name\tbranch\tpath\tstatus
worktree_list() {
  local worktrees_dir="$PROJECT_ROOT/$CFG_WORKTREE_DIR"
  [[ -d "$worktrees_dir" ]] || return 0

  for dir in "$worktrees_dir"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
    local status="idle"
    local ahead=0 behind=0

    if branch_exists "$branch"; then
      ahead=$(git -C "$PROJECT_ROOT" rev-list --count "$CFG_BASE_BRANCH..$branch" 2>/dev/null || echo "0")
      behind=$(git -C "$PROJECT_ROOT" rev-list --count "$branch..$CFG_BASE_BRANCH" 2>/dev/null || echo "0")
    fi

    if (( ahead > 0 )); then
      status="$ahead ahead"
    fi
    if (( behind > 0 )); then
      status="${status:+$status, }$behind behind"
    fi
    if (( ahead == 0 && behind == 0 )); then
      status="clean"
    fi

    # Check for uncommitted changes in the worktree
    if [[ -d "$dir/.git" ]] || [[ -f "$dir/.git" ]]; then
      if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        status="${status:+$status, }dirty"
      fi
    fi

    printf '%s\t%s\t%s\t%s\n' "$name" "$branch" "$dir" "$status"
  done
}

# Check if a worktree exists for a session name.
worktree_exists() {
  local name="$1"
  [[ -d "$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name" ]]
}

# Get the absolute path to a worktree.
worktree_path() {
  local name="$1"
  printf '%s' "$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"
}

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
      worktree_remove "$name" >&2
      removed=$((removed + 1))
    fi
  done

  printf '%d' "$removed"
}

# ── Internal Helpers ─────────────────────────────────────────────────────────

# Install dependencies in a worktree (fast — package managers use shared stores).
_worktree_install_deps() {
  local worktree_path="$1"

  [[ -f "$worktree_path/package.json" ]] || return 0

  local pkg_manager
  pkg_manager="$(detect_pkg_manager "$worktree_path")"

  log_info "Installing dependencies (${pkg_manager})..."
  case "$pkg_manager" in
    pnpm) (cd "$worktree_path" && pnpm install --frozen-lockfile --silent 2>/dev/null) || log_warn "pnpm install failed (non-fatal)" ;;
    yarn) (cd "$worktree_path" && yarn install --frozen-lockfile --silent 2>/dev/null) || log_warn "yarn install failed (non-fatal)" ;;
    bun)  (cd "$worktree_path" && bun install --frozen-lockfile 2>/dev/null)           || log_warn "bun install failed (non-fatal)" ;;
    npm)  (cd "$worktree_path" && npm ci --silent 2>/dev/null)                         || log_warn "npm ci failed (non-fatal)" ;;
  esac
  log_ok "Dependencies installed"
}

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
