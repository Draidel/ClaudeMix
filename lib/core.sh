#!/usr/bin/env bash
# ClaudeMix — core.sh
# Shared utilities, config loading, logging, dependency checks.
# Sourced by all other modules. Never executed directly.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

CLAUDEMIX_VERSION="0.1.0"
CLAUDEMIX_CONFIG_FILE=".claudemix.yml"
CLAUDEMIX_DIR=".claudemix"
CLAUDEMIX_WORKTREES_DIR="$CLAUDEMIX_DIR/worktrees"
CLAUDEMIX_SESSIONS_DIR="$CLAUDEMIX_DIR/sessions"
CLAUDEMIX_BRANCH_PREFIX="claudemix/"
CLAUDEMIX_TMUX_PREFIX="claudemix-"

# ── Colors ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" BOLD="" DIM="" RESET=""
fi

# ── Logging ──────────────────────────────────────────────────────────────────

log_info()  { echo "${BLUE}info${RESET}  $*"; }
log_ok()    { echo "${GREEN}ok${RESET}    $*"; }
log_warn()  { echo "${YELLOW}warn${RESET}  $*" >&2; }
log_error() { echo "${RED}error${RESET} $*" >&2; }
log_debug() { [[ "${CLAUDEMIX_DEBUG:-}" == "1" ]] && echo "${DIM}debug $*${RESET}" >&2 || true; }

die() {
  log_error "$@"
  exit 1
}

# ── Project Detection ────────────────────────────────────────────────────────

# Find the git root of the current project.
# Returns empty string if not in a git repo.
find_project_root() {
  git rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Ensure we're in a git repository and set PROJECT_ROOT.
require_project() {
  PROJECT_ROOT="$(find_project_root)"
  if [[ -z "$PROJECT_ROOT" ]]; then
    die "Not in a git repository. Run this from inside a project."
  fi
  export PROJECT_ROOT
}

# Ensure the .claudemix directory exists.
ensure_claudemix_dir() {
  require_project
  mkdir -p "$PROJECT_ROOT/$CLAUDEMIX_WORKTREES_DIR"
  mkdir -p "$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR"

  # Add to .gitignore if not already there
  local gitignore="$PROJECT_ROOT/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qF "$CLAUDEMIX_DIR/" "$gitignore" 2>/dev/null; then
      echo "" >> "$gitignore"
      echo "# ClaudeMix session data" >> "$gitignore"
      echo "$CLAUDEMIX_DIR/" >> "$gitignore"
      log_debug "Added $CLAUDEMIX_DIR/ to .gitignore"
    fi
  fi
}

# ── Config Loading ───────────────────────────────────────────────────────────

# Default configuration values.
declare -g CFG_VALIDATE=""
declare -g CFG_PROTECTED_BRANCHES="main"
declare -g CFG_MERGE_TARGET=""
declare -g CFG_MERGE_STRATEGY="squash"
declare -g CFG_CLAUDE_FLAGS="--dangerously-skip-permissions"
declare -g CFG_BASE_BRANCH=""
declare -g CFG_WORKTREE_DIR=""

# Parse a simple flat YAML config file (key: value pairs, no nesting).
# Handles comments (#) and blank lines.
load_config() {
  require_project
  local config_path="$PROJECT_ROOT/$CLAUDEMIX_CONFIG_FILE"

  if [[ ! -f "$config_path" ]]; then
    log_debug "No config file found at $config_path, using defaults"
    _detect_defaults
    return 0
  fi

  log_debug "Loading config from $config_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    # Parse key: value
    local key value
    key="$(echo "$line" | sed 's/:.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(echo "$line" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    case "$key" in
      validate)            CFG_VALIDATE="$value" ;;
      protected_branches)  CFG_PROTECTED_BRANCHES="$value" ;;
      merge_target)        CFG_MERGE_TARGET="$value" ;;
      merge_strategy)      CFG_MERGE_STRATEGY="$value" ;;
      claude_flags)        CFG_CLAUDE_FLAGS="$value" ;;
      base_branch)         CFG_BASE_BRANCH="$value" ;;
      worktree_dir)        CFG_WORKTREE_DIR="$value" ;;
      *)                   log_debug "Unknown config key: $key" ;;
    esac
  done < "$config_path"

  _detect_defaults
}

# Auto-detect sensible defaults for unset config values.
_detect_defaults() {
  # Detect validate command
  if [[ -z "$CFG_VALIDATE" ]]; then
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
      if grep -q '"validate"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="pnpm validate"
      elif grep -q '"lint"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="pnpm lint"
      elif grep -q '"test"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="npm test"
      fi
    elif [[ -f "$PROJECT_ROOT/Makefile" ]]; then
      if grep -q '^lint:' "$PROJECT_ROOT/Makefile" 2>/dev/null; then
        CFG_VALIDATE="make lint"
      elif grep -q '^check:' "$PROJECT_ROOT/Makefile" 2>/dev/null; then
        CFG_VALIDATE="make check"
      fi
    elif [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
      CFG_VALIDATE="cargo check && cargo clippy"
    elif [[ -f "$PROJECT_ROOT/go.mod" ]]; then
      CFG_VALIDATE="go vet ./..."
    fi
    log_debug "Auto-detected validate command: ${CFG_VALIDATE:-none}"
  fi

  # Detect default branch
  if [[ -z "$CFG_BASE_BRANCH" ]]; then
    CFG_BASE_BRANCH="$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")"
    if [[ -z "$CFG_BASE_BRANCH" ]]; then
      # Fallback: check common branch names
      for branch in main master staging develop; do
        if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
          CFG_BASE_BRANCH="$branch"
          break
        fi
      done
    fi
    CFG_BASE_BRANCH="${CFG_BASE_BRANCH:-main}"
    log_debug "Auto-detected base branch: $CFG_BASE_BRANCH"
  fi

  # Detect merge target (defaults to base branch)
  if [[ -z "$CFG_MERGE_TARGET" ]]; then
    CFG_MERGE_TARGET="$CFG_BASE_BRANCH"
  fi

  # Worktree directory
  if [[ -z "$CFG_WORKTREE_DIR" ]]; then
    CFG_WORKTREE_DIR="$CLAUDEMIX_WORKTREES_DIR"
  fi
}

# ── Dependency Checks ────────────────────────────────────────────────────────

# Check if a command exists.
has_cmd() {
  command -v "$1" &>/dev/null
}

# Check all required dependencies.
check_dependencies() {
  local missing=()

  if ! has_cmd git; then
    missing+=("git")
  fi

  if ! has_cmd claude; then
    missing+=("claude (Claude Code CLI — https://docs.anthropic.com/en/docs/claude-code)")
  fi

  if (( ${#missing[@]} > 0 )); then
    die "Missing required dependencies: ${missing[*]}"
  fi

  # Optional but recommended
  if ! has_cmd tmux; then
    log_warn "tmux not installed. Sessions will run in foreground (no persistence)."
    log_warn "Install with: brew install tmux"
  fi

  if ! has_cmd gum; then
    log_warn "gum not installed. Interactive menus disabled (using basic prompts)."
    log_warn "Install with: brew install gum"
  fi

  if ! has_cmd gh; then
    log_warn "GitHub CLI not installed. Merge queue PR creation disabled."
    log_warn "Install with: brew install gh"
  fi
}

# ── Utility Functions ────────────────────────────────────────────────────────

# Get the current git branch name.
current_branch() {
  git -C "${1:-$PROJECT_ROOT}" symbolic-ref --short HEAD 2>/dev/null || echo ""
}

# Check if a git branch exists locally.
branch_exists() {
  git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Check if tmux is available and running.
tmux_available() {
  has_cmd tmux
}

# Check if gum is available.
gum_available() {
  has_cmd gum
}

# Check if we're currently inside a tmux session.
in_tmux() {
  [[ -n "${TMUX:-}" ]]
}

# Sanitize a session name (alphanumeric, hyphens, underscores only).
sanitize_name() {
  echo "$1" | tr -cs 'a-zA-Z0-9_-' '-' | sed 's/^-//;s/-$//'
}

# Format a timestamp for display.
format_time() {
  local timestamp="$1"
  if has_cmd gdate; then
    gdate -d "$timestamp" '+%b %d %H:%M' 2>/dev/null || echo "$timestamp"
  elif date -d "$timestamp" '+%b %d %H:%M' 2>/dev/null; then
    :
  else
    # macOS date fallback
    echo "$timestamp" | sed 's/T/ /;s/\+.*//' | cut -c1-16
  fi
}

# ISO 8601 timestamp.
now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
