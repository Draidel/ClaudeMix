# shellcheck shell=bash
# ClaudeMix — merge-queue.sh
# Consolidate multiple session branches into a single PR.
# Reduces CI churn when many Claude sessions work in parallel.
# Sourced by bin/claudemix. Never executed directly.

# ── Merge Queue Operations ───────────────────────────────────────────────────

# Interactive merge queue: select branches, consolidate, create PR.
merge_queue_run() {
  if ! has_cmd gh; then
    die "GitHub CLI (gh) is required for merge queue. Install: brew install gh (macOS) | see https://cli.github.com/"
  fi

  # Collect claudemix branches with commits ahead of merge target
  local -a branches=()
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local ahead
    ahead=$(git -C "$PROJECT_ROOT" rev-list --count "$CFG_MERGE_TARGET..$branch" 2>/dev/null || echo "0")
    if (( ahead > 0 )); then
      branches+=("$branch ($ahead commits)")
    fi
  done < <(git -C "$PROJECT_ROOT" branch --list "${CLAUDEMIX_BRANCH_PREFIX}*" 2>/dev/null | sed 's/^[* ]*//')

  if (( ${#branches[@]} == 0 )); then
    log_info "No branches ready to merge."
    return 0
  fi

  # Select branches to consolidate
  local -a selected=()
  if gum_available; then
    log_info "Select branches to consolidate into a single PR:"
    local choices
    choices="$(printf '%s\n' "${branches[@]}" | gum choose --no-limit \
      --header "Select branches (space to toggle, enter to confirm)")" || return 0
    while IFS= read -r choice; do
      [[ -z "$choice" ]] && continue
      selected+=("$(printf '%s' "$choice" | sed 's/ (.*//')")
    done <<< "$choices"
  else
    printf '\nAvailable branches:\n'
    local idx=1
    for branch in "${branches[@]}"; do
      printf '  %d) %s\n' "$idx" "$branch"
      idx=$((idx + 1))
    done
    printf '\nEnter branch numbers to merge (comma-separated, e.g., 1,3,5): '
    read -r selections
    IFS=',' read -ra nums <<< "$selections"
    for num in "${nums[@]}"; do
      num="$(printf '%s' "$num" | tr -d '[:space:]')"
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#branches[@]} )); then
        local branch_entry="${branches[$((num-1))]}"
        selected+=("$(printf '%s' "$branch_entry" | sed 's/ (.*//')")
      fi
    done
  fi

  if (( ${#selected[@]} == 0 )); then
    log_info "No branches selected."
    return 0
  fi

  log_info "Selected ${#selected[@]} branch(es) for consolidation"

  # Record the current branch so we can restore it on error
  local original_branch
  original_branch="$(current_branch)"

  # Create consolidated merge branch
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  local merge_branch="claudemix/merge-${timestamp}"

  # Trap to restore original branch on failure
  trap '_merge_queue_restore_branch "$original_branch" "$merge_branch"' EXIT

  log_info "Creating consolidated branch ${CYAN}$merge_branch${RESET} from ${CYAN}$CFG_MERGE_TARGET${RESET}"

  git -C "$PROJECT_ROOT" checkout "$CFG_MERGE_TARGET" --quiet 2>/dev/null
  git -C "$PROJECT_ROOT" pull origin "$CFG_MERGE_TARGET" --quiet 2>/dev/null || true
  git -C "$PROJECT_ROOT" checkout -b "$merge_branch" --quiet 2>/dev/null || {
    die "Failed to create merge branch"
  }

  # Merge each selected branch
  local merged=0
  local -a failed=()
  for branch in "${selected[@]}"; do
    log_info "Merging ${CYAN}$branch${RESET}..."
    if git -C "$PROJECT_ROOT" merge "$branch" --no-edit --quiet 2>/dev/null; then
      merged=$((merged + 1))
      log_ok "Merged $branch"
    else
      log_error "Conflict merging $branch — aborting this merge"
      git -C "$PROJECT_ROOT" merge --abort 2>/dev/null || true
      failed+=("$branch")
    fi
  done

  if (( merged == 0 )); then
    log_error "No branches could be merged. Cleaning up."
    git -C "$PROJECT_ROOT" checkout "$CFG_MERGE_TARGET" --quiet 2>/dev/null
    git -C "$PROJECT_ROOT" branch -D "$merge_branch" 2>/dev/null || true
    trap - EXIT
    return 1
  fi

  # Run validation on consolidated result
  if [[ -n "$CFG_VALIDATE" ]]; then
    log_info "Running validation on consolidated branch..."
    if ! (cd "$PROJECT_ROOT" && bash -c "$CFG_VALIDATE"); then
      log_error "Validation failed on consolidated branch."
      log_warn "Fix issues and run: git push -u origin $merge_branch && gh pr create"
      trap - EXIT
      return 1
    fi
    log_ok "Validation passed"
  fi

  # Push and create PR
  log_info "Pushing ${CYAN}$merge_branch${RESET}..."
  git -C "$PROJECT_ROOT" push -u origin "$merge_branch" 2>/dev/null || {
    die "Failed to push branch"
  }

  # Build PR body using printf (portable, no echo -e)
  local pr_body
  pr_body="$(printf '## Consolidated PR\n\nMerges %d branch(es) from ClaudeMix sessions:\n\n' "$merged")"
  for branch in "${selected[@]}"; do
    local is_failed=false
    for f in "${failed[@]+"${failed[@]}"}"; do
      [[ "$f" == "$branch" ]] && is_failed=true && break
    done
    if $is_failed; then
      # shellcheck disable=SC2016 # Backticks are literal markdown, not command substitution
      pr_body+="$(printf -- '- ❌ `%s` (conflict — skipped)\n' "$branch")"
    else
      # shellcheck disable=SC2016 # Backticks are literal markdown
      pr_body+="$(printf -- '- ✅ `%s`\n' "$branch")"
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    pr_body+="$(printf '\n### Skipped (conflicts)\n\nThese branches had conflicts and need manual resolution:\n\n')"
    for branch in "${failed[@]}"; do
      # shellcheck disable=SC2016 # Backticks are literal markdown
      pr_body+="$(printf -- '- `%s`\n' "$branch")"
    done
  fi

  pr_body+="$(printf '\n---\n*Generated by [ClaudeMix](https://github.com/Draidel/ClaudeMix)*')"

  local pr_title="chore: consolidate ${merged} ClaudeMix session(s)"

  log_info "Creating PR..."
  local pr_url
  pr_url="$(gh pr create \
    --base "$CFG_MERGE_TARGET" \
    --head "$merge_branch" \
    --title "$pr_title" \
    --body "$pr_body" \
    2>/dev/null)" || {
    die "Failed to create PR. Push succeeded — create manually: gh pr create"
  }

  log_ok "PR created: $pr_url"

  # Enable auto-merge if squash strategy
  if [[ "$CFG_MERGE_STRATEGY" == "squash" ]]; then
    gh pr merge --auto --squash "$pr_url" 2>/dev/null || true
    log_ok "Auto-merge enabled (squash)"
  fi

  # Clear the trap and return to original branch
  trap - EXIT
  git -C "$PROJECT_ROOT" checkout "${original_branch:-$CFG_MERGE_TARGET}" --quiet 2>/dev/null || true

  printf '\n'
  log_ok "Consolidated ${GREEN}$merged${RESET} branches into ${CYAN}$pr_url${RESET}"
  if (( ${#failed[@]} > 0 )); then
    log_warn "${#failed[@]} branch(es) skipped due to conflicts"
  fi
}

# List branches eligible for merge queue.
merge_queue_list() {
  local branches
  branches="$(git -C "$PROJECT_ROOT" branch --list "${CLAUDEMIX_BRANCH_PREFIX}*" 2>/dev/null | sed 's/^[* ]*//')"

  if [[ -z "$branches" ]]; then
    log_info "No ClaudeMix branches found."
    return 0
  fi

  printf "${BOLD}%-35s %-8s %-8s %s${RESET}\n" "BRANCH" "AHEAD" "BEHIND" "STATUS"
  printf "%-35s %-8s %-8s %s\n" "──────" "─────" "──────" "──────"

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local ahead behind status
    ahead=$(git -C "$PROJECT_ROOT" rev-list --count "$CFG_MERGE_TARGET..$branch" 2>/dev/null || echo "?")
    behind=$(git -C "$PROJECT_ROOT" rev-list --count "$branch..$CFG_MERGE_TARGET" 2>/dev/null || echo "?")

    if [[ "$ahead" == "0" ]]; then
      status="${DIM}merged${RESET}"
    elif [[ "$behind" != "0" ]]; then
      status="${YELLOW}needs rebase${RESET}"
    else
      status="${GREEN}ready${RESET}"
    fi

    printf "%-35s %-8s %-8s %b\n" "$branch" "+$ahead" "-$behind" "$status"
  done <<< "$branches"
}

# ── Internal Helpers ─────────────────────────────────────────────────────────

# Restore the original branch and clean up merge branch on failure.
_merge_queue_restore_branch() {
  local original_branch="$1"
  local merge_branch="$2"
  log_warn "Restoring to ${original_branch:-$CFG_MERGE_TARGET} after error"
  git -C "$PROJECT_ROOT" checkout "${original_branch:-$CFG_MERGE_TARGET}" --quiet 2>/dev/null || true
  if [[ -n "$merge_branch" ]] && branch_exists "$merge_branch"; then
    git -C "$PROJECT_ROOT" branch -D "$merge_branch" 2>/dev/null || true
  fi
}
