# ClaudeMix — core.sh
# Foundation: constants, colors, logging, config, dependency checks, utilities.
# Sourced by bin/claudemix. Never executed directly.

# ── Constants ────────────────────────────────────────────────────────────────

readonly CLAUDEMIX_VERSION="0.2.0"
readonly CLAUDEMIX_CONFIG_FILE=".claudemix.yml"
readonly CLAUDEMIX_DIR=".claudemix"
readonly CLAUDEMIX_WORKTREES_DIR="$CLAUDEMIX_DIR/worktrees"
readonly CLAUDEMIX_SESSIONS_DIR="$CLAUDEMIX_DIR/sessions"
readonly CLAUDEMIX_BRANCH_PREFIX="claudemix/"
readonly CLAUDEMIX_TMUX_PREFIX="claudemix-"

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

log_info()  { printf '%s\n' "${BLUE}info${RESET}  $*"; }
log_ok()    { printf '%s\n' "${GREEN}ok${RESET}    $*"; }
log_warn()  { printf '%s\n' "${YELLOW}warn${RESET}  $*" >&2; }
log_error() { printf '%s\n' "${RED}error${RESET} $*" >&2; }
log_debug() {
  if [[ "${CLAUDEMIX_DEBUG:-}" == "1" ]]; then
    printf '%s\n' "${DIM}debug $*${RESET}" >&2
  fi
}

die() {
  log_error "$@"
  exit 1
}

# ── Project Detection ────────────────────────────────────────────────────────

# Find the git root of the current project.
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

# Ensure the .claudemix directory structure exists.
ensure_claudemix_dir() {
  mkdir -p "$PROJECT_ROOT/$CLAUDEMIX_WORKTREES_DIR"
  mkdir -p "$PROJECT_ROOT/$CLAUDEMIX_SESSIONS_DIR"

  # Add to .gitignore if not already present
  local gitignore="$PROJECT_ROOT/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qF "$CLAUDEMIX_DIR/" "$gitignore" 2>/dev/null; then
      printf '\n# ClaudeMix session data\n%s/\n' "$CLAUDEMIX_DIR" >> "$gitignore"
      log_debug "Added $CLAUDEMIX_DIR/ to .gitignore"
    fi
  fi
}

# ── Package Manager Detection ────────────────────────────────────────────────

# Detect the package manager for a given directory.
# Args: $1 = directory path (defaults to PROJECT_ROOT)
# Output: pnpm | yarn | bun | npm
detect_pkg_manager() {
  local dir="${1:-$PROJECT_ROOT}"
  if [[ -f "$dir/pnpm-lock.yaml" ]] || [[ -f "$dir/pnpm-workspace.yaml" ]]; then
    printf 'pnpm'
  elif [[ -f "$dir/yarn.lock" ]]; then
    printf 'yarn'
  elif [[ -f "$dir/bun.lockb" ]] || [[ -f "$dir/bun.lock" ]]; then
    printf 'bun'
  else
    printf 'npm'
  fi
}

# ── Config Loading ───────────────────────────────────────────────────────────

# Default configuration values (global, mutable).
declare -g CFG_VALIDATE=""
declare -g CFG_PROTECTED_BRANCHES="main"
declare -g CFG_MERGE_TARGET=""
declare -g CFG_MERGE_STRATEGY="squash"
declare -g CFG_CLAUDE_FLAGS="--dangerously-skip-permissions"
declare -g CFG_BASE_BRANCH=""
declare -g CFG_WORKTREE_DIR=""

# Parse a flat YAML config file (key: value, no nesting).
# Handles comments, blank lines, and colons in values.
load_config() {
  local config_path="$PROJECT_ROOT/$CLAUDEMIX_CONFIG_FILE"

  if [[ ! -f "$config_path" ]]; then
    log_debug "No config file found, using defaults"
    _detect_defaults
    return 0
  fi

  log_debug "Loading config from $config_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip inline comments and skip blank lines
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue

    # Parse key: value using regex (handles colons in values correctly)
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Trim trailing whitespace
      value="${value%"${value##*[![:space:]]}"}"

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
    fi
  done < "$config_path"

  _detect_defaults
}

# Auto-detect sensible defaults for unset config values.
_detect_defaults() {
  # Detect validate command
  if [[ -z "$CFG_VALIDATE" ]]; then
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
      local pm
      pm="$(detect_pkg_manager "$PROJECT_ROOT")"
      if grep -q '"validate"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="$pm validate"
      elif grep -q '"lint"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="$pm lint"
      elif grep -q '"test"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
        CFG_VALIDATE="$pm test"
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
    log_debug "Auto-detected validate: ${CFG_VALIDATE:-none}"
  fi

  # Detect default branch
  if [[ -z "$CFG_BASE_BRANCH" ]]; then
    CFG_BASE_BRANCH="$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
      | sed 's@^refs/remotes/origin/@@' || echo "")"
    if [[ -z "$CFG_BASE_BRANCH" ]]; then
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

  # Merge target defaults to base branch
  if [[ -z "$CFG_MERGE_TARGET" ]]; then
    CFG_MERGE_TARGET="$CFG_BASE_BRANCH"
  fi

  # Worktree directory
  if [[ -z "$CFG_WORKTREE_DIR" ]]; then
    CFG_WORKTREE_DIR="$CLAUDEMIX_WORKTREES_DIR"
  fi
}

# Write default config to a file.
# Args: $1 = output path
write_default_config() {
  local config_path="$1"
  cat > "$config_path" << EOF
# ClaudeMix configuration
# https://github.com/Draidel/ClaudeMix

validate: ${CFG_VALIDATE:-npm test}
protected_branches: ${CFG_PROTECTED_BRANCHES}
merge_target: ${CFG_MERGE_TARGET}
merge_strategy: ${CFG_MERGE_STRATEGY}
base_branch: ${CFG_BASE_BRANCH}
claude_flags: ${CFG_CLAUDE_FLAGS}
EOF
}

# ── Dependency Checks ────────────────────────────────────────────────────────

# Check if a command is available on PATH.
has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Check required and optional dependencies. Dies if required ones are missing.
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

  # Warn about optional dependencies with cross-platform install hints
  if ! has_cmd tmux; then
    log_warn "tmux not installed. Sessions run in foreground (no persistence)."
    log_warn "Install: brew install tmux (macOS) | apt install tmux (Debian/Ubuntu)"
  fi

  if ! has_cmd gum; then
    log_warn "gum not installed. Interactive menus disabled (basic prompts instead)."
    log_warn "Install: brew install gum (macOS) | see https://github.com/charmbracelet/gum#installation"
  fi

  if ! has_cmd gh; then
    log_warn "gh not installed. Merge queue PR creation disabled."
    log_warn "Install: brew install gh (macOS) | see https://cli.github.com/"
  fi
}

# ── Utility Functions ────────────────────────────────────────────────────────

# Get the current git branch name. Empty string if detached HEAD.
current_branch() {
  git -C "${1:-$PROJECT_ROOT}" symbolic-ref --short HEAD 2>/dev/null || echo ""
}

# Check if a git branch exists locally.
branch_exists() {
  git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Check if tmux is available.
tmux_available() {
  has_cmd tmux
}

# Check if gum is available.
gum_available() {
  has_cmd gum
}

# Check if we're inside a tmux session.
in_tmux() {
  [[ -n "${TMUX:-}" ]]
}

# Sanitize a session name to alphanumeric, hyphens, and underscores.
# Dies if the input produces an empty name.
sanitize_name() {
  local input="${1:-}"
  local result
  result="$(printf '%s' "$input" | tr -cs 'a-zA-Z0-9_-' '-' | sed 's/^-*//;s/-*$//')"
  if [[ -z "$result" ]]; then
    die "Invalid session name: '$input'. Use alphanumeric characters, hyphens, or underscores."
  fi
  printf '%s' "$result"
}

# Format an ISO 8601 timestamp for display.
format_time() {
  local timestamp="$1"
  # GNU date (Linux or macOS with coreutils)
  if has_cmd gdate; then
    gdate -d "$timestamp" '+%b %d %H:%M' 2>/dev/null && return 0
  fi
  if date --version >/dev/null 2>&1; then
    date -d "$timestamp" '+%b %d %H:%M' 2>/dev/null && return 0
  fi
  # BSD date (macOS) — simple fallback
  printf '%s' "$timestamp" | sed 's/T/ /;s/[+Z].*//' | cut -c1-16
}

# Generate an ISO 8601 UTC timestamp.
now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
