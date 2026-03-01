# shellcheck shell=bash
# ClaudeMix — tui.sh
# Interactive TUI with dashboard display and hotkey navigation.
# Uses pure ANSI for rendering, gum for interactive inputs (with fallback).
# Sourced by bin/claudemix. Never executed directly.

# ── Dashboard Data ─────────────────────────────────────────────────────────

# Dashboard state (populated by _tui_gather_data)
declare -g _TUI_SESSION_COUNT=0
declare -g _TUI_SESSION_NAMES=""
declare -g _TUI_SESSION_LINES=""
declare -g _TUI_MERGE_READY=0
declare -g _TUI_MERGE_REBASE=0
declare -g _TUI_WORKTREE_SIZE=""
declare -g _TUI_PROJECT_BRANCH=""
declare -g _TUI_PROJECT_STATUS=""
declare -g _TUI_HOOKS_INSTALLED=""

# Collect all dashboard data in one pass.
_tui_gather_data() {
  _TUI_SESSION_COUNT=0
  _TUI_SESSION_NAMES=""
  _TUI_SESSION_LINES=""
  _TUI_MERGE_READY=0
  _TUI_MERGE_REBASE=0

  # Current project branch + ahead/behind
  _TUI_PROJECT_BRANCH="$(current_branch "$PROJECT_ROOT")"
  _TUI_PROJECT_BRANCH="${_TUI_PROJECT_BRANCH:-detached}"
  local proj_ahead=0 proj_behind=0
  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/remotes/origin/$_TUI_PROJECT_BRANCH" 2>/dev/null; then
    proj_ahead=$(git -C "$PROJECT_ROOT" rev-list --count "origin/$_TUI_PROJECT_BRANCH..$_TUI_PROJECT_BRANCH" 2>/dev/null || printf '0')
    proj_behind=$(git -C "$PROJECT_ROOT" rev-list --count "$_TUI_PROJECT_BRANCH..origin/$_TUI_PROJECT_BRANCH" 2>/dev/null || printf '0')
  fi
  _TUI_PROJECT_STATUS=""
  if (( proj_ahead > 0 )); then _TUI_PROJECT_STATUS="${_TUI_PROJECT_STATUS}+${proj_ahead}"; fi
  if (( proj_behind > 0 )); then _TUI_PROJECT_STATUS="${_TUI_PROJECT_STATUS:+$_TUI_PROJECT_STATUS }-${proj_behind}"; fi

  # Hook status (check for .git/hooks/pre-commit with claudemix marker)
  _TUI_HOOKS_INSTALLED=""
  local hook_file="$PROJECT_ROOT/.git/hooks/pre-commit"
  if [[ -f "$hook_file" ]] && grep -q 'claudemix' "$hook_file" 2>/dev/null; then
    _TUI_HOOKS_INSTALLED="1"
  fi

  # Sessions from raw worktree data
  local -a raw_sessions=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    raw_sessions+=("$entry")
    _TUI_SESSION_COUNT=$((_TUI_SESSION_COUNT + 1))
  done < <(session_list "raw")

  # Build session index (name list for numbered targeting)
  _TUI_SESSION_NAMES=""
  for entry in "${raw_sessions[@]+"${raw_sessions[@]}"}"; do
    local sn="${entry%%|*}"
    _TUI_SESSION_NAMES+="${sn}"$'\n'
  done

  # Build rich session lines
  local idx=0
  _TUI_SESSION_LINES=""
  for entry in "${raw_sessions[@]+"${raw_sessions[@]}"}"; do
    idx=$((idx + 1))
    IFS='|' read -r s_name s_branch s_status s_git s_created <<< "$entry"

    # Running indicator
    local indicator="${RED}o${RESET}"
    [[ "$s_status" == "running" ]] && indicator="${GREEN}*${RESET}"

    # Parse ahead/behind from git status field
    local ahead_num=0 behind_num=0
    if [[ "$s_git" =~ ([0-9]+)\ ahead ]]; then
      ahead_num="${BASH_REMATCH[1]}"
    fi
    if [[ "$s_git" =~ ([0-9]+)\ behind ]]; then
      behind_num="${BASH_REMATCH[1]}"
    fi

    # Build compact status: "+3!" or "+0~" or "clean"
    local status_str=""
    if (( ahead_num > 0 )) || (( behind_num > 0 )) || [[ "$s_git" == *"dirty"* ]]; then
      status_str="${CYAN}+${ahead_num}${RESET}"
      if (( behind_num > 0 )); then
        status_str="${status_str}${YELLOW}!${RESET}"
      fi
      if [[ "$s_git" == *"dirty"* ]]; then
        status_str="${status_str}${YELLOW}~${RESET}"
      fi
    else
      status_str="${DIM}ok${RESET}"
    fi

    # Age
    local age=""
    if [[ -n "$s_created" ]]; then
      age="$(_tui_format_age "$s_created")"
    fi

    # Validation cache
    local val_status
    val_status="$(session_validate_status "$s_name")"
    local val_display=""
    case "$val_status" in
      pass)    val_display="${GREEN}v${RESET}" ;;
      fail)    val_display="${RED}x${RESET}" ;;
      *)       val_display="${DIM}-${RESET}" ;;
    esac

    # Compact line: "  1 * name       +3!~  2h v"
    local name_pad=$((12 - ${#s_name}))
    if (( name_pad < 1 )); then name_pad=1; fi

    local status_visible
    status_visible="$(_tui_strip_ansi "$status_str")"
    local status_pad=$((6 - ${#status_visible}))
    if (( status_pad < 1 )); then status_pad=1; fi

    local age_pad=$((4 - ${#age}))
    if (( age_pad < 1 )); then age_pad=1; fi

    _TUI_SESSION_LINES+="$(printf '  %s %b %s%*s%b%*s%b%*s%b' \
      "$idx" "$indicator" \
      "$s_name" "$name_pad" "" \
      "$status_str" "$status_pad" "" \
      "${DIM}${age}${RESET}" "$age_pad" "" \
      "$val_display")"
    _TUI_SESSION_LINES+=$'\n'
  done

  # Merge queue breakdown
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local br_ahead br_behind
    br_ahead=$(git -C "$PROJECT_ROOT" rev-list --count "$CFG_MERGE_TARGET..$branch" 2>/dev/null || printf '0')
    br_behind=$(git -C "$PROJECT_ROOT" rev-list --count "$branch..$CFG_MERGE_TARGET" 2>/dev/null || printf '0')
    if (( br_ahead > 0 )); then
      if (( br_behind > 0 )); then
        _TUI_MERGE_REBASE=$((_TUI_MERGE_REBASE + 1))
      else
        _TUI_MERGE_READY=$((_TUI_MERGE_READY + 1))
      fi
    fi
  done < <(git -C "$PROJECT_ROOT" branch --list "${CLAUDEMIX_BRANCH_PREFIX}*" 2>/dev/null | sed 's/^[* ]*//')

  # Worktree disk usage
  local wt_dir="$PROJECT_ROOT/$CFG_WORKTREE_DIR"
  if [[ -d "$wt_dir" ]]; then
    _TUI_WORKTREE_SIZE="$(du -sh "$wt_dir" 2>/dev/null | cut -f1 | tr -d '[:space:]')"
  else
    _TUI_WORKTREE_SIZE=""
  fi
}

# Format an ISO timestamp as relative age (e.g., "3m", "2h", "1d").
_tui_format_age() {
  local ts="$1"
  local now_epoch ts_epoch diff

  now_epoch="$(date '+%s' 2>/dev/null || printf '0')"

  # Try GNU date first, then BSD date
  if has_cmd gdate; then
    ts_epoch="$(gdate -d "$ts" '+%s' 2>/dev/null || printf '0')"
  elif date --version >/dev/null 2>&1; then
    ts_epoch="$(date -d "$ts" '+%s' 2>/dev/null || printf '0')"
  else
    # BSD date (macOS) — force UTC since timestamps are stored as UTC
    local converted
    converted="$(printf '%s' "$ts" | sed 's/T/ /;s/Z//')"
    ts_epoch="$(TZ=UTC0 date -j -f '%Y-%m-%d %H:%M:%S' "$converted" '+%s' 2>/dev/null || printf '0')"
  fi

  if (( ts_epoch == 0 )); then
    printf '?'
    return 0
  fi

  diff=$((now_epoch - ts_epoch))
  if (( diff < 0 )); then
    printf 'now'
  elif (( diff < 60 )); then
    printf '%ds' "$diff"
  elif (( diff < 3600 )); then
    printf '%dm' "$((diff / 60))"
  elif (( diff < 86400 )); then
    printf '%dh' "$((diff / 3600))"
  else
    printf '%dd' "$((diff / 86400))"
  fi
}

# ── Dashboard Renderer ─────────────────────────────────────────────────────

# Print a full-width ASCII divider line.
_tui_divider() {
  local w="${1:-40}"
  local i=0 line=""
  while (( i < w )); do
    line+="-"
    i=$((i + 1))
  done
  printf '  %b%s%b\n' "$DIM" "$line" "$RESET"
}

# Render the full dashboard to stdout.
_tui_render_dashboard() {
  # Responsive width based on terminal
  local term_width="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
  local width=$((term_width - 4))
  if (( width > 76 )); then width=76; fi
  if (( width < 30 )); then width=30; fi

  # Clear screen for clean redraw
  printf '\033[2J\033[H'

  # ── Header ──
  local right_info="${DIM}${_TUI_PROJECT_BRANCH}${RESET}"
  if [[ -n "$_TUI_PROJECT_STATUS" ]]; then
    right_info="${right_info} ${_TUI_PROJECT_STATUS}"
  fi
  if [[ -n "$_TUI_HOOKS_INSTALLED" ]]; then
    right_info="${right_info} ${GREEN}[hooks]${RESET}"
  fi

  printf '\n'
  local title="ClaudeMix v${CLAUDEMIX_VERSION}"
  local right_visible
  right_visible="$(_tui_strip_ansi "$right_info")"
  local header_pad=$((width - ${#title} - ${#right_visible}))
  if (( header_pad < 1 )); then header_pad=1; fi
  printf '  %b%s%b%*s%b\n' \
    "$BOLD" "$title" "$RESET" \
    "$header_pad" "" "$right_info"
  _tui_divider "$width"

  # ── Sessions ──
  local session_label="SESSIONS"
  if (( _TUI_SESSION_COUNT > 0 )); then
    session_label="SESSIONS ${DIM}(${_TUI_SESSION_COUNT})${RESET}"
  fi
  printf '  %b%b\n' "$BOLD" "${session_label}${RESET}"

  if (( _TUI_SESSION_COUNT == 0 )); then
    printf '  %bNo sessions. Press n to start one.%b\n' "$DIM" "$RESET"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '%s\n' "$line"
    done <<< "$_TUI_SESSION_LINES"
  fi

  _tui_divider "$width"

  # ── Merge Queue ──
  local merge_info=""
  if (( _TUI_MERGE_READY > 0 )); then
    merge_info="${GREEN}${_TUI_MERGE_READY} ready${RESET}"
  else
    merge_info="${DIM}0 ready${RESET}"
  fi
  if (( _TUI_MERGE_REBASE > 0 )); then
    merge_info="${merge_info} ${YELLOW}${_TUI_MERGE_REBASE} rebase${RESET}"
  fi
  printf '  %bMERGE%b %b->%b %s %b(%s)%b  %b\n' \
    "$BOLD" "$RESET" "$DIM" "$RESET" \
    "$CFG_MERGE_TARGET" "$DIM" "$CFG_MERGE_STRATEGY" "$RESET" \
    "$merge_info"

  _tui_divider "$width"

  # ── Health (one compact line) ──
  local health=""
  health+="$(_tui_health_check git)"
  health+=" $(_tui_health_check claude)"
  health+=" $(_tui_health_check tmux)"
  health+=" $(_tui_health_check gum)"
  health+=" $(_tui_health_check gh)"
  if [[ -n "$_TUI_WORKTREE_SIZE" ]]; then
    health+="  ${DIM}${_TUI_WORKTREE_SIZE}${RESET}"
  fi
  printf '  %b\n' "$health"

  # ── Action Bar ──
  printf '\n'
  if (( _TUI_SESSION_COUNT > 0 && _TUI_SESSION_COUNT <= 9 )); then
    printf '  %bn%b new  %b1-%s%b attach  %bm%b merge  %bk%b kill  %bv%b validate\n' \
      "$BOLD" "$RESET" "$BOLD" "$_TUI_SESSION_COUNT" "$RESET" \
      "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
  else
    printf '  %bn%b new  %ba%b attach  %bm%b merge  %bk%b kill  %bv%b validate\n' \
      "$BOLD" "$RESET" "$BOLD" "$RESET" \
      "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
  fi
  printf '  %bc%b cleanup  %bh%b hooks  %bi%b config  %bq%b quit\n' \
    "$BOLD" "$RESET" "$BOLD" "$RESET" \
    "$BOLD" "$RESET" "$BOLD" "$RESET"
  printf '\n'
}

# ── Rendering Helpers ──────────────────────────────────────────────────────

# Strip ANSI escape sequences for visible-length calculation.
_tui_strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\[[0-9;]*m//g'
}

# Health check: compact "Xcmd" format (all ASCII).
_tui_health_check() {
  local cmd="$1"
  if has_cmd "$cmd"; then
    printf '%b+%s%b' "$GREEN" "$cmd" "$RESET"
  else
    printf '%b-%s%b' "$RED" "$cmd" "$RESET"
  fi
}

# ── Main Menu ────────────────────────────────────────────────────────────────

# Get session name by 1-based index from the gathered data.
_tui_session_name_at() {
  local target="$1" idx=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    idx=$((idx + 1))
    if (( idx == target )); then
      printf '%s' "$name"
      return 0
    fi
  done <<< "$_TUI_SESSION_NAMES"
  return 1
}

# Show the interactive dashboard + hotkey menu loop.
tui_main_menu() {
  ensure_claudemix_dir

  while true; do
    _tui_gather_data
    _tui_render_dashboard

    # Read single keypress (no enter needed)
    local key=""
    read -rsn1 key 2>/dev/null || key=""

    case "$key" in
      # Number keys: attach to session by index
      [1-9])
        if (( key <= _TUI_SESSION_COUNT )); then
          local target_name
          target_name="$(_tui_session_name_at "$key")"
          if [[ -n "$target_name" ]]; then
            session_attach "$target_name"
          fi
        fi
        ;;
      n|N) _tui_new_session ;;
      a|A) _tui_attach_session ;;
      m|M) _tui_merge_menu ;;
      k|K) _tui_kill_session ;;
      v|V) _tui_validate_all ;;
      c|C) _tui_cleanup ;;
      h|H) _tui_hooks_menu ;;
      i|I) _tui_init ;;
      r|R) ;; # Explicit refresh (loop redraws)
      q|Q) return 0 ;;
      "")  ;; # Enter = refresh
      *)   ;; # Unknown key = refresh
    esac
  done
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

# ── Validate All ─────────────────────────────────────────────────────────────

_tui_validate_all() {
  if [[ -z "$CFG_VALIDATE" ]]; then
    log_warn "No validation command configured. Set 'validate' in .claudemix.yml"
    _tui_pause
    return 0
  fi

  local -a names=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && names+=("$n")
  done < <(session_list "names")

  if (( ${#names[@]} == 0 )); then
    log_info "No sessions to validate."
    _tui_pause
    return 0
  fi

  printf '\n'
  for n in "${names[@]}"; do
    session_validate "$n" || true
  done

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
