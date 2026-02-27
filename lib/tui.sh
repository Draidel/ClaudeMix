#!/usr/bin/env bash
# ClaudeMix — tui.sh
# Interactive TUI menus using gum (with fallback to basic prompts).
# Sourced by other modules. Never executed directly.

# ── Main Menu ────────────────────────────────────────────────────────────────

# Show the interactive main menu.
tui_main_menu() {
  ensure_claudemix_dir
  load_config

  while true; do
    local action
    action="$(_tui_choose_action)"

    case "$action" in
      new)     _tui_new_session ;;
      attach)  _tui_attach_session ;;
      list)    session_list "table"; _tui_pause ;;
      merge)   merge_queue_run ;;
      cleanup) _tui_cleanup ;;
      kill)    _tui_kill_session ;;
      hooks)   _tui_hooks_menu ;;
      init)    _tui_init ;;
      quit)    return 0 ;;
      *)       return 0 ;;
    esac
  done
}

# ── Action Chooser ───────────────────────────────────────────────────────────

_tui_choose_action() {
  # Count active sessions for display
  local session_count=0
  while IFS= read -r _; do
    ((session_count++))
  done < <(session_list "names")

  local header="ClaudeMix v${CLAUDEMIX_VERSION}"
  if (( session_count > 0 )); then
    header="$header — $session_count active session(s)"
  fi

  if gum_available; then
    local choice
    choice="$(gum choose \
      --header "$header" \
      --cursor.foreground="6" \
      "New session" \
      "Attach to session" \
      "List sessions" \
      "Merge queue" \
      "Cleanup merged" \
      "Kill session" \
      "Git hooks" \
      "Init config" \
      "Quit" \
    )" || return 0

    case "$choice" in
      "New session")        echo "new" ;;
      "Attach to session")  echo "attach" ;;
      "List sessions")      echo "list" ;;
      "Merge queue")        echo "merge" ;;
      "Cleanup merged")     echo "cleanup" ;;
      "Kill session")       echo "kill" ;;
      "Git hooks")          echo "hooks" ;;
      "Init config")        echo "init" ;;
      "Quit")               echo "quit" ;;
    esac
  else
    echo ""
    echo "${BOLD}$header${RESET}"
    echo ""
    echo "  1) New session"
    echo "  2) Attach to session"
    echo "  3) List sessions"
    echo "  4) Merge queue"
    echo "  5) Cleanup merged"
    echo "  6) Kill session"
    echo "  7) Git hooks"
    echo "  8) Init config"
    echo "  9) Quit"
    echo ""
    echo -n "Choose: "
    read -r num
    case "$num" in
      1) echo "new" ;;
      2) echo "attach" ;;
      3) echo "list" ;;
      4) echo "merge" ;;
      5) echo "cleanup" ;;
      6) echo "kill" ;;
      7) echo "hooks" ;;
      8) echo "init" ;;
      9|q) echo "quit" ;;
      *) echo "quit" ;;
    esac
  fi
}

# ── New Session ──────────────────────────────────────────────────────────────

_tui_new_session() {
  local name

  if gum_available; then
    name="$(gum input \
      --placeholder "Session name (e.g., auth-fix, ui-update)" \
      --header "New Session" \
      --char-limit=50 \
      --width=50 \
    )" || return 0
  else
    echo -n "Session name: "
    read -r name
  fi

  name="$(sanitize_name "$name")"
  if [[ -z "$name" ]]; then
    log_warn "No name provided."
    return 0
  fi

  session_create "$name"
}

# ── Attach Session ───────────────────────────────────────────────────────────

_tui_attach_session() {
  local names=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(session_list "names")

  if (( ${#names[@]} == 0 )); then
    log_info "No sessions to attach to."
    _tui_pause
    return 0
  fi

  local selected
  if gum_available; then
    selected="$(printf '%s\n' "${names[@]}" | gum choose --header "Attach to session")" || return 0
  else
    echo "Sessions:"
    local i=1
    for n in "${names[@]}"; do
      echo "  $i) $n"
      ((i++))
    done
    echo -n "Choose: "
    read -r num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#names[@]} )); then
      selected="${names[$((num-1))]}"
    fi
  fi

  if [[ -n "${selected:-}" ]]; then
    session_attach "$selected"
  fi
}

# ── Kill Session ─────────────────────────────────────────────────────────────

_tui_kill_session() {
  local names=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(session_list "names")

  if (( ${#names[@]} == 0 )); then
    log_info "No sessions to kill."
    _tui_pause
    return 0
  fi

  local selected
  if gum_available; then
    selected="$(printf '%s\n' "${names[@]}" "ALL" | gum choose --header "Kill session")" || return 0
  else
    echo "Sessions:"
    local i=1
    for n in "${names[@]}"; do
      echo "  $i) $n"
      ((i++))
    done
    echo "  a) ALL"
    echo -n "Choose: "
    read -r num
    if [[ "$num" == "a" ]]; then
      selected="ALL"
    elif [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#names[@]} )); then
      selected="${names[$((num-1))]}"
    fi
  fi

  if [[ "${selected:-}" == "ALL" ]]; then
    session_kill_all
  elif [[ -n "${selected:-}" ]]; then
    local keep="keep"
    if gum_available; then
      if gum confirm "Also remove worktree and branch?"; then
        keep=""
      fi
    else
      echo -n "Also remove worktree and branch? [y/N] "
      read -r yn
      [[ "$yn" =~ ^[Yy] ]] && keep=""
    fi
    session_kill "$selected" "$keep"
  fi

  _tui_pause
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

_tui_cleanup() {
  log_info "Scanning for merged worktrees..."
  local removed
  removed="$(worktree_cleanup_merged)"

  if (( removed > 0 )); then
    log_ok "Cleaned up $removed worktree(s)"
  else
    log_info "No merged worktrees to clean up."
  fi

  # Also prune git worktrees
  git -C "$PROJECT_ROOT" worktree prune 2>/dev/null || true

  _tui_pause
}

# ── Hooks Menu ───────────────────────────────────────────────────────────────

_tui_hooks_menu() {
  local action
  if gum_available; then
    action="$(gum choose \
      --header "Git Hooks" \
      "Install hooks" \
      "Uninstall hooks" \
      "Show status" \
      "Back" \
    )" || return 0
  else
    echo ""
    echo "  1) Install hooks"
    echo "  2) Uninstall hooks"
    echo "  3) Show status"
    echo "  4) Back"
    echo -n "Choose: "
    read -r num
    case "$num" in
      1) action="Install hooks" ;;
      2) action="Uninstall hooks" ;;
      3) action="Show status" ;;
      *) return 0 ;;
    esac
  fi

  case "$action" in
    "Install hooks")   hooks_install ;;
    "Uninstall hooks") hooks_uninstall ;;
    "Show status")     hooks_status ;;
    "Back")            return 0 ;;
  esac

  _tui_pause
}

# ── Init Config ──────────────────────────────────────────────────────────────

_tui_init() {
  local config_path="$PROJECT_ROOT/$CLAUDEMIX_CONFIG_FILE"

  if [[ -f "$config_path" ]]; then
    log_warn "Config already exists: $config_path"
    if gum_available; then
      gum confirm "Overwrite?" || return 0
    else
      echo -n "Overwrite? [y/N] "
      read -r yn
      [[ "$yn" =~ ^[Yy] ]] || return 0
    fi
  fi

  # Auto-detect and write config
  _detect_defaults

  cat > "$config_path" << EOF
# ClaudeMix configuration
# https://github.com/Draidel/ClaudeMix

# Command to validate code before push (auto-detected)
validate: ${CFG_VALIDATE:-npm test}

# Branches that cannot be pushed to directly (comma-separated)
protected_branches: ${CFG_PROTECTED_BRANCHES}

# Target branch for merge queue PRs
merge_target: ${CFG_MERGE_TARGET}

# Merge strategy: squash, merge, or rebase
merge_strategy: ${CFG_MERGE_STRATEGY}

# Base branch for new worktrees
base_branch: ${CFG_BASE_BRANCH}

# Extra flags to pass to Claude Code
claude_flags: ${CFG_CLAUDE_FLAGS}
EOF

  log_ok "Config written to $config_path"
  _tui_pause
}

# ── Helpers ──────────────────────────────────────────────────────────────────

_tui_pause() {
  if gum_available; then
    echo ""
    gum input --placeholder "Press Enter to continue..." --width=40 > /dev/null 2>&1 || true
  else
    echo ""
    echo -n "Press Enter to continue..."
    read -r
  fi
}
