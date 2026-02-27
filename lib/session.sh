# ClaudeMix — session.sh
# Session lifecycle: create, attach, list, kill.
# A session = worktree + (optional) tmux session + Claude Code process.
# Sourced by bin/claudemix. Never executed directly.

# ── Session Operations ───────────────────────────────────────────────────────

# Create a new session and launch Claude Code in it.
# Args: $1 = session name, remaining args = extra claude flags
session_create() {
  local name
  name="$(sanitize_name "$1")"
  shift

  ensure_claudemix_dir

  # Attach if already running
  if _session_is_running "$name"; then
    log_info "Session ${CYAN}$name${RESET} is already running. Attaching..."
    session_attach "$name"
    return $?
  fi

  # Create isolated worktree
  worktree_create "$name"
  local wt_path="$WORKTREE_PATH"

  # Build claude command as an array (safe — no eval)
  local -a claude_cmd=(claude)
  if [[ -n "$CFG_CLAUDE_FLAGS" ]]; then
    local -a flags
    read -ra flags <<< "$CFG_CLAUDE_FLAGS"
    claude_cmd+=("${flags[@]}")
  fi
  if (( $# > 0 )); then
    claude_cmd+=("$@")
  fi

  # Persist session metadata
  _session_save_meta "$name" "$wt_path"

  # Launch in tmux (persistent) or foreground (ephemeral)
  if tmux_available; then
    _session_launch_tmux "$name" "$wt_path" "${claude_cmd[@]}"
  else
    _session_launch_direct "$name" "$wt_path" "${claude_cmd[@]}"
  fi
}

# Attach to an existing tmux session.
# Args: $1 = session name
session_attach() {
  local name
  name="$(sanitize_name "$1")"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  if ! tmux_available; then
    die "Cannot attach: tmux is not installed. Session may be running in foreground."
  fi

  if ! tmux has-session -t "=$tmux_name" 2>/dev/null; then
    # Tmux session gone but worktree exists — relaunch
    if worktree_exists "$name"; then
      log_info "Session ${CYAN}$name${RESET} has a worktree but no tmux session. Relaunching..."
      session_create "$name"
      return $?
    else
      die "Session '$name' not found."
    fi
  fi

  if in_tmux; then
    tmux switch-client -t "=$tmux_name"
  else
    tmux attach-session -t "=$tmux_name"
  fi
}

# List all sessions with their status.
# Args: $1 = format ("table", "names", "raw")
session_list() {
  local format="${1:-table}"
  local -a sessions=()

  # Collect data from worktrees
  while IFS=$'\t' read -r wt_name wt_branch wt_path wt_status; do
    [[ -z "$wt_name" ]] && continue
    local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${wt_name}"
    local tmux_status="stopped"
    local created_at=""

    # Check tmux status (exact name match with =prefix)
    if tmux_available && tmux has-session -t "=$tmux_name" 2>/dev/null; then
      tmux_status="running"
    fi

    # Read metadata
    local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${wt_name}.meta"
    if [[ -f "$meta_file" ]]; then
      created_at="$(grep '^created_at=' "$meta_file" 2>/dev/null | cut -d= -f2- || echo "")"
    fi

    sessions+=("$wt_name|$wt_branch|$tmux_status|$wt_status|$created_at")
  done < <(worktree_list)

  # Detect orphaned tmux sessions (tmux exists but worktree was removed)
  if tmux_available; then
    while IFS= read -r tmux_session; do
      [[ -z "$tmux_session" ]] && continue
      # Only match sessions with our exact prefix
      [[ "$tmux_session" == "${CLAUDEMIX_TMUX_PREFIX}"* ]] || continue
      local session_name="${tmux_session#"$CLAUDEMIX_TMUX_PREFIX"}"
      local found=false
      for s in "${sessions[@]+"${sessions[@]}"}"; do
        if [[ "$s" == "$session_name|"* ]]; then
          found=true
          break
        fi
      done
      if ! $found; then
        sessions+=("$session_name|(orphaned)|running|no worktree|")
      fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  fi

  if (( ${#sessions[@]} == 0 )); then
    [[ "$format" == "table" ]] && log_info "No active sessions."
    return 0
  fi

  case "$format" in
    table)
      printf "${BOLD}%-20s %-30s %-10s %-20s %s${RESET}\n" "NAME" "BRANCH" "STATUS" "GIT" "CREATED"
      printf "%-20s %-30s %-10s %-20s %s\n" "────" "──────" "──────" "───" "───────"
      for entry in "${sessions[@]}"; do
        IFS='|' read -r s_name s_branch s_status s_git s_created <<< "$entry"
        local status_color="$RED"
        [[ "$s_status" == "running" ]] && status_color="$GREEN"
        local created_display=""
        if [[ -n "$s_created" ]]; then
          created_display="$(format_time "$s_created")"
        fi
        printf "%-20s %-30s ${status_color}%-10s${RESET} %-20s %s\n" \
          "$s_name" "$s_branch" "$s_status" "$s_git" "$created_display"
      done
      ;;
    names)
      for entry in "${sessions[@]}"; do
        printf '%s\n' "${entry%%|*}"
      done
      ;;
    raw)
      for entry in "${sessions[@]}"; do
        printf '%s\n' "$entry"
      done
      ;;
  esac
}

# Kill a session (tmux + optionally remove worktree).
# Args: $1 = session name, $2 = "keep" to keep worktree/branch
session_kill() {
  local name
  name="$(sanitize_name "$1")"
  local keep_worktree="${2:-}"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  # Kill tmux session (exact name match)
  if tmux_available && tmux has-session -t "=$tmux_name" 2>/dev/null; then
    tmux kill-session -t "=$tmux_name" 2>/dev/null || true
    log_ok "tmux session ${CYAN}$tmux_name${RESET} killed"
  fi

  # Remove session metadata
  rm -f "$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"

  # Remove worktree unless asked to keep
  if [[ "$keep_worktree" != "keep" ]]; then
    if worktree_exists "$name"; then
      worktree_remove "$name" "keep-branch"
      log_ok "Worktree removed (branch kept for merge queue)"
    fi
  fi
}

# Kill ALL sessions.
session_kill_all() {
  local killed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    session_kill "$name"
    killed=$((killed + 1))
  done < <(session_list "names")

  if (( killed > 0 )); then
    log_ok "Killed $killed session(s)"
  else
    log_info "No sessions to kill"
  fi
}

# ── Internal Helpers ─────────────────────────────────────────────────────────

# Check if a session is currently running in tmux (exact match).
_session_is_running() {
  local name="$1"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"
  tmux_available && tmux has-session -t "=$tmux_name" 2>/dev/null
}

# Launch Claude in a new tmux session.
# Args: $1 = name, $2 = worktree path, $3+ = claude command array
_session_launch_tmux() {
  local name="$1"
  local wt_path="$2"
  shift 2
  local -a cmd=("$@")
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  # Build a shell-safe command string for tmux
  local safe_cmd=""
  for arg in "${cmd[@]}"; do
    safe_cmd+="$(printf '%q ' "$arg")"
  done
  safe_cmd="${safe_cmd% }"

  log_info "Launching Claude in tmux session ${CYAN}$tmux_name${RESET}"

  local tmux_shell_cmd="${safe_cmd}; printf '\\nClaude exited. Press Enter to close.\\n'; read"

  if in_tmux; then
    tmux new-session -d -s "$tmux_name" -c "$wt_path" "$tmux_shell_cmd"
    tmux switch-client -t "=$tmux_name"
  else
    tmux new-session -s "$tmux_name" -c "$wt_path" "$tmux_shell_cmd"
  fi
}

# Launch Claude directly (no tmux, no eval).
# Args: $1 = name, $2 = worktree path, $3+ = claude command array
_session_launch_direct() {
  local name="$1"
  local wt_path="$2"
  shift 2

  log_warn "Running without tmux (session won't persist if terminal closes)"
  log_info "Starting Claude in ${DIM}$wt_path${RESET}"
  (cd "$wt_path" && "$@")
}

# Persist session metadata.
_session_save_meta() {
  local name="$1"
  local wt_path="$2"
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"

  cat > "$meta_file" << EOF
name=$name
created_at=$(now_iso)
branch=${CLAUDEMIX_BRANCH_PREFIX}${name}
worktree=$wt_path
tmux_session=${CLAUDEMIX_TMUX_PREFIX}${name}
base_branch=$CFG_BASE_BRANCH
EOF
}
