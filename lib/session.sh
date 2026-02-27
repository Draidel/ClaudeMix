#!/usr/bin/env bash
# ClaudeMix — session.sh
# Session lifecycle: create, attach, list, kill.
# A session = worktree + (optional) tmux session + Claude Code process.
# Sourced by other modules. Never executed directly.

# ── Session Operations ───────────────────────────────────────────────────────

# Create a new session and launch Claude Code in it.
# Args: $1 = session name, $@ (rest) = extra claude flags
session_create() {
  local name
  name="$(sanitize_name "$1")"
  shift

  if [[ -z "$name" ]]; then
    die "Session name is required."
  fi

  ensure_claudemix_dir

  # Check if session already exists and is running
  if session_is_running "$name"; then
    log_info "Session ${CYAN}$name${RESET} is already running. Attaching..."
    session_attach "$name"
    return $?
  fi

  # Create worktree
  worktree_create "$name"
  local wt_path="$WORKTREE_PATH"

  # Build claude command
  local claude_cmd="claude"
  if [[ -n "$CFG_CLAUDE_FLAGS" ]]; then
    claude_cmd="claude $CFG_CLAUDE_FLAGS"
  fi
  # Append any extra flags passed by the user
  if (( $# > 0 )); then
    claude_cmd="$claude_cmd $*"
  fi

  # Save session metadata
  _session_save_meta "$name" "$wt_path"

  if tmux_available; then
    _session_launch_tmux "$name" "$wt_path" "$claude_cmd"
  else
    _session_launch_direct "$name" "$wt_path" "$claude_cmd"
  fi
}

# Attach to an existing session.
# Args: $1 = session name
session_attach() {
  local name
  name="$(sanitize_name "$1")"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  if ! tmux_available; then
    die "Cannot attach: tmux is not installed. Session may be running in foreground."
  fi

  if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
    # Session doesn't exist in tmux — check if worktree exists
    if worktree_exists "$name"; then
      log_info "Session ${CYAN}$name${RESET} has a worktree but no tmux session. Relaunching..."
      session_create "$name"
      return $?
    else
      die "Session '$name' not found."
    fi
  fi

  if in_tmux; then
    tmux switch-client -t "$tmux_name"
  else
    tmux attach-session -t "$tmux_name"
  fi
}

# List all sessions with their status.
# Output format depends on caller (raw data or formatted).
session_list() {
  local format="${1:-table}"
  local sessions=()

  # Collect data from worktrees
  while IFS=$'\t' read -r wt_name wt_branch wt_path wt_status; do
    local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${wt_name}"
    local tmux_status="stopped"
    local created_at=""

    # Check tmux status
    if tmux_available && tmux has-session -t "$tmux_name" 2>/dev/null; then
      tmux_status="running"
    fi

    # Read metadata
    local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${wt_name}.meta"
    if [[ -f "$meta_file" ]]; then
      created_at="$(grep '^created_at=' "$meta_file" 2>/dev/null | cut -d= -f2- || echo "")"
    fi

    sessions+=("$wt_name|$wt_branch|$tmux_status|$wt_status|$created_at")
  done < <(worktree_list)

  # Also check for tmux sessions without worktrees (orphaned)
  if tmux_available; then
    while IFS= read -r tmux_session; do
      local session_name="${tmux_session#"$CLAUDEMIX_TMUX_PREFIX"}"
      local found=false
      for s in "${sessions[@]}"; do
        if [[ "$s" == "$session_name|"* ]]; then
          found=true
          break
        fi
      done
      if ! $found; then
        sessions+=("$session_name|(orphaned)|running|no worktree|")
      fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CLAUDEMIX_TMUX_PREFIX}" || true)
  fi

  if (( ${#sessions[@]} == 0 )); then
    if [[ "$format" == "table" ]]; then
      log_info "No active sessions."
    fi
    return 0
  fi

  if [[ "$format" == "table" ]]; then
    printf "${BOLD}%-20s %-30s %-10s %-20s %s${RESET}\n" "NAME" "BRANCH" "STATUS" "GIT" "CREATED"
    printf "%-20s %-30s %-10s %-20s %s\n" "────" "──────" "──────" "───" "───────"
    for entry in "${sessions[@]}"; do
      IFS='|' read -r s_name s_branch s_status s_git s_created <<< "$entry"
      local status_color="$RED"
      if [[ "$s_status" == "running" ]]; then
        status_color="$GREEN"
      fi
      local created_display=""
      if [[ -n "$s_created" ]]; then
        created_display="$(format_time "$s_created")"
      fi
      printf "%-20s %-30s ${status_color}%-10s${RESET} %-20s %s\n" \
        "$s_name" "$s_branch" "$s_status" "$s_git" "$created_display"
    done
  elif [[ "$format" == "names" ]]; then
    for entry in "${sessions[@]}"; do
      echo "${entry%%|*}"
    done
  elif [[ "$format" == "raw" ]]; then
    for entry in "${sessions[@]}"; do
      echo "$entry"
    done
  fi
}

# Kill a session (tmux + optionally remove worktree).
# Args: $1 = session name, $2 = "keep" to keep worktree
session_kill() {
  local name
  name="$(sanitize_name "$1")"
  local keep_worktree="${2:-}"

  if [[ -z "$name" ]]; then
    die "Session name is required."
  fi

  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  # Kill tmux session
  if tmux_available && tmux has-session -t "$tmux_name" 2>/dev/null; then
    tmux kill-session -t "$tmux_name" 2>/dev/null || true
    log_ok "tmux session ${CYAN}$tmux_name${RESET} killed"
  fi

  # Remove session metadata
  local meta_file="$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR/${name}.meta"
  rm -f "$meta_file"

  # Remove worktree unless asked to keep
  if [[ "$keep_worktree" != "keep" ]]; then
    if worktree_exists "$name"; then
      worktree_remove "$name" "keep-branch"
      log_ok "Worktree removed (branch kept for merge queue)"
    fi
  fi
}

# Check if a session is currently running in tmux.
session_is_running() {
  local name="$1"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"
  tmux_available && tmux has-session -t "$tmux_name" 2>/dev/null
}

# Kill ALL sessions.
session_kill_all() {
  local killed=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    session_kill "$name"
    ((killed++))
  done < <(session_list "names")

  if (( killed > 0 )); then
    log_ok "Killed $killed session(s)"
  else
    log_info "No sessions to kill"
  fi
}

# ── Internal Helpers ─────────────────────────────────────────────────────────

# Launch Claude in a tmux session.
_session_launch_tmux() {
  local name="$1"
  local wt_path="$2"
  local claude_cmd="$3"
  local tmux_name="${CLAUDEMIX_TMUX_PREFIX}${name}"

  log_info "Launching Claude in tmux session ${CYAN}$tmux_name${RESET}"

  if in_tmux; then
    # Already in tmux — create new session and switch to it
    tmux new-session -d -s "$tmux_name" -c "$wt_path" "$claude_cmd; echo 'Claude exited. Press Enter to close.'; read"
    tmux switch-client -t "$tmux_name"
  else
    # Not in tmux — create and attach
    tmux new-session -s "$tmux_name" -c "$wt_path" "$claude_cmd; echo 'Claude exited. Press Enter to close.'; read"
  fi
}

# Launch Claude directly (no tmux).
_session_launch_direct() {
  local name="$1"
  local wt_path="$2"
  local claude_cmd="$3"

  log_warn "Running without tmux (session won't persist if terminal closes)"
  log_info "Starting Claude in ${DIM}$wt_path${RESET}"
  (cd "$wt_path" && eval "$claude_cmd")
}

# Save session metadata to a file.
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
