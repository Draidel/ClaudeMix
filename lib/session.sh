# shellcheck shell=bash
# ClaudeMix — session.sh
# Session lifecycle: create, attach, list, kill.
# A session = worktree + (optional) tmux session + Claude Code process.
# Sourced by bin/claudemix. Never executed directly.

# ── Session Operations ───────────────────────────────────────────────────────

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

  # Build safe claude command string for comparison
  local safe_claude=""
  for arg in "${claude_cmd[@]}"; do
    safe_claude+="$(printf '%q ' "$arg")"
  done
  safe_claude="${safe_claude% }"

  while IFS=$'\t' read -r direction cmd; do
    pane_dirs+=("$direction")
    pane_cmds+=("${cmd}; printf '\\nProcess exited. Press Enter to close.\\n'; read")
    if [[ "$cmd" == "$safe_claude" ]]; then
      claude_pane_idx=$pane_idx
    fi
    pane_idx=$((pane_idx + 1))
  done < <(_parse_panes "$panes" "${claude_cmd[@]}")

  # Create session with first pane
  tmux new-session -d -s "$tmux_name" -c "$wt_path" "${pane_cmds[0]}"

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
