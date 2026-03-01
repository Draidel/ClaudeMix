# shellcheck shell=bash
# ClaudeMix — tui.sh
# Interactive TUI menus using gum (with fallback to basic prompts).
# Sourced by bin/claudemix. Never executed directly.

# ── Main Menu ────────────────────────────────────────────────────────────────

# Show the interactive main menu loop.
tui_main_menu() {
  ensure_claudemix_dir

  while true; do
    local action
    action="$(_tui_choose_action)"

    case "$action" in
      new)       _tui_new_session ;;
      attach)    _tui_attach_session ;;
      open)      _tui_open_session ;;
      close)     _tui_close_session ;;
      list)      session_list "table"; _tui_pause ;;
      merge)     _tui_merge_menu ;;
      cleanup)   _tui_cleanup ;;
      kill)      _tui_kill_session ;;
      dashboard) dashboard_run ;;
      hooks)     _tui_hooks_menu ;;
      init)      _tui_init ;;
      config)    _tui_config_menu ;;
      quit)      return 0 ;;
      *)         return 0 ;;
    esac
  done
}

# ── Action Chooser ───────────────────────────────────────────────────────────

_tui_choose_action() {
  # Count active sessions
  local session_count=0
  while IFS= read -r _line; do
    session_count=$((session_count + 1))
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
      "Open session" \
      "Close session" \
      "List sessions" \
      "Merge queue" \
      "Cleanup merged" \
      "Kill session" \
      "Dashboard" \
      "Git hooks" \
      "Init config" \
      "Global config" \
      "Quit" \
    )" || { printf 'quit'; return 0; }

    case "$choice" in
      "New session")        printf 'new' ;;
      "Attach to session")  printf 'attach' ;;
      "Open session")       printf 'open' ;;
      "Close session")      printf 'close' ;;
      "List sessions")      printf 'list' ;;
      "Merge queue")        printf 'merge' ;;
      "Cleanup merged")     printf 'cleanup' ;;
      "Kill session")       printf 'kill' ;;
      "Dashboard")          printf 'dashboard' ;;
      "Git hooks")          printf 'hooks' ;;
      "Init config")        printf 'init' ;;
      "Global config")      printf 'config' ;;
      "Quit")               printf 'quit' ;;
    esac
  else
    printf '\n%s\n\n' "${BOLD}$header${RESET}"
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
    printf 'Choose: '
    read -r num
    case "$num" in
      1) printf 'new' ;;
      2) printf 'attach' ;;
      3) printf 'open' ;;
      4) printf 'close' ;;
      5) printf 'list' ;;
      6) printf 'merge' ;;
      7) printf 'cleanup' ;;
      8) printf 'kill' ;;
      9) printf 'dashboard' ;;
      10) printf 'hooks' ;;
      11) printf 'init' ;;
      12) printf 'config' ;;
      13|q) printf 'quit' ;;
      *) printf 'quit' ;;
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
    printf 'Session name: '
    read -r name
  fi

  name="$(sanitize_name "${name:-}")" || { log_warn "Invalid name."; return 0; }
  session_create "$name"
}

# ── Attach Session ───────────────────────────────────────────────────────────

_tui_attach_session() {
  local -a names=()
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
    printf 'Sessions:\n'
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
    session_attach "$selected"
  fi
}

# ── Kill Session ─────────────────────────────────────────────────────────────

_tui_kill_session() {
  local -a names=()
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
    printf 'Sessions:\n'
    local idx=1
    for n in "${names[@]}"; do
      printf '  %d) %s\n' "$idx" "$n"
      idx=$((idx + 1))
    done
    printf '  a) ALL\nChoose: '
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
      printf 'Also remove worktree and branch? [y/N] '
      read -r yn
      [[ "$yn" =~ ^[Yy] ]] && keep=""
    fi
    session_kill "$selected" "$keep"
  fi

  _tui_pause
}

# ── Open Session ────────────────────────────────────────────────────────────

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

# ── Close Session ───────────────────────────────────────────────────────────

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

# ── Config Menu ─────────────────────────────────────────────────────────────

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

  git -C "$PROJECT_ROOT" worktree prune 2>/dev/null || true
  _tui_pause
}

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
    printf '\n  1) Install hooks\n  2) Uninstall hooks\n  3) Show status\n  4) Back\nChoose: '
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
      printf 'Overwrite? [y/N] '
      read -r yn
      [[ "$yn" =~ ^[Yy] ]] || return 0
    fi
  fi

  _detect_defaults
  write_default_config "$config_path"
  log_ok "Config written to $config_path"
  _tui_pause
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Pause and wait for user to press Enter.
_tui_pause() {
  printf '\nPress Enter to continue...'
  read -r
}
