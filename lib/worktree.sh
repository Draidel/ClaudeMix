#!/usr/bin/env bash
# ClaudeMix — worktree.sh
# Git worktree lifecycle management.
# Sourced by other modules. Never executed directly.

# ── Worktree Operations ──────────────────────────────────────────────────────

# Create a new worktree for a session.
# Args: $1 = session name
# Returns: 0 on success, 1 on failure
# Sets: WORKTREE_PATH (absolute path to the created worktree)
worktree_create() {
  local name="$1"
  local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
  local worktree_path="$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"

  if [[ -d "$worktree_path" ]]; then
    log_debug "Worktree already exists: $worktree_path"
    WORKTREE_PATH="$worktree_path"
    return 0
  fi

  # Ensure base branch is up to date
  log_info "Creating worktree ${CYAN}$name${RESET} from ${CYAN}$CFG_BASE_BRANCH${RESET}"
  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$CFG_BASE_BRANCH" 2>/dev/null; then
    git -C "$PROJECT_ROOT" fetch origin "$CFG_BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  # Create the branch + worktree
  if branch_exists "$branch"; then
    # Branch exists, just add worktree
    git -C "$PROJECT_ROOT" worktree add "$worktree_path" "$branch" 2>/dev/null || {
      die "Failed to create worktree. Branch '$branch' may already have a worktree."
    }
  else
    # Create new branch from base
    git -C "$PROJECT_ROOT" worktree add -b "$branch" "$worktree_path" "$CFG_BASE_BRANCH" 2>/dev/null || {
      die "Failed to create worktree from '$CFG_BASE_BRANCH'. Is the branch available?"
    }
  fi

  WORKTREE_PATH="$worktree_path"
  log_ok "Worktree created at ${DIM}$worktree_path${RESET}"

  # Run package install if applicable (fast — uses shared store)
  _worktree_install_deps "$worktree_path"

  return 0
}

# Remove a worktree and optionally its branch.
# Args: $1 = session name, $2 = "keep-branch" to keep the branch
worktree_remove() {
  local name="$1"
  local keep_branch="${2:-}"
  local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
  local worktree_path="$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"

  if [[ ! -d "$worktree_path" ]]; then
    log_debug "Worktree not found: $worktree_path"
    return 0
  fi

  log_info "Removing worktree ${CYAN}$name${RESET}"
  git -C "$PROJECT_ROOT" worktree remove "$worktree_path" --force 2>/dev/null || {
    # If git worktree remove fails, try manual cleanup
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
  if [[ ! -d "$worktrees_dir" ]]; then
    return 0
  fi

  for dir in "$worktrees_dir"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"
    local status="idle"

    # Check if branch has commits ahead/behind base
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

    # Check for dirty working tree
    if [[ -d "$dir/.git" ]] || [[ -f "$dir/.git" ]]; then
      if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        status="${status:+$status, }dirty"
      fi
    fi

    printf '%s\t%s\t%s\t%s\n' "$name" "$branch" "$dir" "$status"
  done
}

# Check if a worktree exists for a given session name.
worktree_exists() {
  local name="$1"
  [[ -d "$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name" ]]
}

# Get the path to a worktree.
worktree_path() {
  local name="$1"
  echo "$PROJECT_ROOT/$CFG_WORKTREE_DIR/$name"
}

# Clean up worktrees whose branches have been merged into the merge target.
# Returns: number of worktrees removed
worktree_cleanup_merged() {
  local removed=0
  local worktrees_dir="$PROJECT_ROOT/$CFG_WORKTREE_DIR"

  if [[ ! -d "$worktrees_dir" ]]; then
    echo "$removed"
    return 0
  fi

  # Get list of merged branches
  local merged_branches
  merged_branches="$(git -C "$PROJECT_ROOT" branch --merged "$CFG_MERGE_TARGET" 2>/dev/null | sed 's/^[* ]*//' || echo "")"

  for dir in "$worktrees_dir"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local branch="${CLAUDEMIX_BRANCH_PREFIX}${name}"

    if echo "$merged_branches" | grep -qF "$branch"; then
      log_info "Branch ${CYAN}$branch${RESET} is merged into ${CYAN}$CFG_MERGE_TARGET${RESET}"
      worktree_remove "$name"
      ((removed++))
    fi
  done

  echo "$removed"
}

# ── Internal Helpers ─────────────────────────────────────────────────────────

# Install dependencies in a worktree (fast — package managers use shared stores).
_worktree_install_deps() {
  local worktree_path="$1"

  if [[ -f "$worktree_path/package.json" ]]; then
    local pkg_manager="npm"
    if [[ -f "$worktree_path/pnpm-lock.yaml" ]] || [[ -f "$worktree_path/pnpm-workspace.yaml" ]]; then
      pkg_manager="pnpm"
    elif [[ -f "$worktree_path/yarn.lock" ]]; then
      pkg_manager="yarn"
    elif [[ -f "$worktree_path/bun.lockb" ]]; then
      pkg_manager="bun"
    fi

    log_info "Installing dependencies (${pkg_manager})..."
    case "$pkg_manager" in
      pnpm)  (cd "$worktree_path" && pnpm install --frozen-lockfile --silent 2>/dev/null) || log_warn "pnpm install failed (non-fatal)" ;;
      yarn)  (cd "$worktree_path" && yarn install --frozen-lockfile --silent 2>/dev/null) || log_warn "yarn install failed (non-fatal)" ;;
      bun)   (cd "$worktree_path" && bun install --frozen-lockfile 2>/dev/null) || log_warn "bun install failed (non-fatal)" ;;
      npm)   (cd "$worktree_path" && npm ci --silent 2>/dev/null) || log_warn "npm ci failed (non-fatal)" ;;
    esac
    log_ok "Dependencies installed"
  fi
}
