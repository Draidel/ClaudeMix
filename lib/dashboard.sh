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
