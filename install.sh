#!/usr/bin/env bash
# ClaudeMix installer
# Usage: curl -sSL https://raw.githubusercontent.com/Draidel/ClaudeMix/main/install.sh | bash
#
# Environment variables:
#   CLAUDEMIX_HOME   Override installation directory (default: ~/.claudemix)

set -euo pipefail

REPO="https://github.com/Draidel/ClaudeMix.git"
INSTALL_DIR="${CLAUDEMIX_HOME:-$HOME/.claudemix}"
BIN_NAME="claudemix"

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

info()  { printf '%s\n' "${CYAN}info${RESET}  $*"; }
ok()    { printf '%s\n' "${GREEN}ok${RESET}    $*"; }
warn()  { printf '%s\n' "${YELLOW}warn${RESET}  $*" >&2; }
error() { printf '%s\n' "${RED}error${RESET} $*" >&2; }

# ── Pre-flight Checks ────────────────────────────────────────────────────────

if ! command -v git >/dev/null 2>&1; then
  error "git is required. Install it first."
  exit 1
fi

# ── Install / Update ─────────────────────────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]]; then
  # Validate this looks like a ClaudeMix installation before any destructive ops
  if [[ ! -f "$INSTALL_DIR/bin/claudemix" ]] && [[ ! -d "$INSTALL_DIR/.git" ]]; then
    error "Directory '$INSTALL_DIR' exists but doesn't look like a ClaudeMix installation."
    error "Set CLAUDEMIX_HOME to a different path or remove the directory manually."
    exit 1
  fi
  info "Updating existing installation at $INSTALL_DIR"
  if ! (cd "$INSTALL_DIR" && git pull --quiet origin main); then
    warn "Git pull failed. Reinstalling..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR" || {
      error "Failed to clone repository. Check your network connection."
      exit 1
    }
  fi
else
  info "Installing ClaudeMix to $INSTALL_DIR"
  git clone --depth 1 "$REPO" "$INSTALL_DIR" || {
    error "Failed to clone repository. Check your network connection."
    exit 1
  }
fi

chmod +x "$INSTALL_DIR/bin/$BIN_NAME"

# ── Shell Integration ─────────────────────────────────────────────────────────

BIN_PATH="$INSTALL_DIR/bin"
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
SHELL_RC=""

case "$SHELL_NAME" in
  zsh)
    SHELL_RC="$HOME/.zshrc"
    ;;
  bash)
    if [[ -f "$HOME/.bash_profile" ]]; then
      SHELL_RC="$HOME/.bash_profile"
    elif [[ -f "$HOME/.bashrc" ]]; then
      SHELL_RC="$HOME/.bashrc"
    else
      SHELL_RC="$HOME/.bashrc"
    fi
    ;;
  fish)
    SHELL_RC="$HOME/.config/fish/config.fish"
    ;;
  *)
    warn "Unsupported shell: $SHELL_NAME. Add $BIN_PATH to your PATH manually."
    ;;
esac

if [[ -n "$SHELL_RC" ]]; then
  local_path_line="export PATH=\"$BIN_PATH:\$PATH\""
  if [[ "$SHELL_NAME" == "fish" ]]; then
    local_path_line="fish_add_path $BIN_PATH"
  fi

  if ! grep -qF "$BIN_PATH" "$SHELL_RC" 2>/dev/null; then
    printf '\n# ClaudeMix\n%s\n' "$local_path_line" >> "$SHELL_RC"
    ok "Added $BIN_PATH to PATH in $SHELL_RC"
  else
    info "PATH already configured in $SHELL_RC"
  fi

  # Install shell completions
  if [[ "$SHELL_NAME" == "zsh" ]]; then
    local_completions="$HOME/.zsh/completions"
    if mkdir -p "$local_completions" 2>/dev/null; then
      if [[ -f "$INSTALL_DIR/completions/$BIN_NAME.zsh" ]]; then
        cp "$INSTALL_DIR/completions/$BIN_NAME.zsh" "$local_completions/_$BIN_NAME"
        info "Zsh completions installed to $local_completions"
      fi
    fi
  elif [[ "$SHELL_NAME" == "bash" ]]; then
    local_completions="$HOME/.local/share/bash-completion/completions"
    if mkdir -p "$local_completions" 2>/dev/null; then
      if [[ -f "$INSTALL_DIR/completions/$BIN_NAME.bash" ]]; then
        cp "$INSTALL_DIR/completions/$BIN_NAME.bash" "$local_completions/$BIN_NAME"
        info "Bash completions installed to $local_completions"
      fi
    fi
  elif [[ "$SHELL_NAME" == "fish" ]]; then
    local_completions="$HOME/.config/fish/completions"
    if mkdir -p "$local_completions" 2>/dev/null; then
      if [[ -f "$INSTALL_DIR/completions/$BIN_NAME.fish" ]]; then
        cp "$INSTALL_DIR/completions/$BIN_NAME.fish" "$local_completions/$BIN_NAME.fish"
        info "Fish completions installed to $local_completions"
      fi
    fi
  fi
fi

# ── Check Optional Dependencies ───────────────────────────────────────────────

printf '\n'
info "Checking optional dependencies..."

missing_optional=()
if ! command -v tmux >/dev/null 2>&1; then
  missing_optional+=("tmux (session persistence)")
fi
if ! command -v gum >/dev/null 2>&1; then
  missing_optional+=("gum (interactive TUI)")
fi
if ! command -v gh >/dev/null 2>&1; then
  missing_optional+=("gh (merge queue PRs)")
fi
if ! command -v claude >/dev/null 2>&1; then
  missing_optional+=("claude (Claude Code CLI — https://docs.anthropic.com/en/docs/claude-code)")
fi

if (( ${#missing_optional[@]} > 0 )); then
  warn "Optional dependencies not found:"
  for dep in "${missing_optional[@]}"; do
    printf '  - %s\n' "$dep"
  done
  printf '\n'
  # Cross-platform install hints
  if command -v brew >/dev/null 2>&1; then
    info "Install with: brew install tmux gum gh"
  elif command -v apt-get >/dev/null 2>&1; then
    info "Install tmux: sudo apt install tmux"
    info "Install gum: see https://github.com/charmbracelet/gum#installation"
    info "Install gh: see https://cli.github.com/"
  else
    info "See individual project pages for installation instructions."
  fi
  printf '\n'
  info "ClaudeMix works without these but some features will be limited."
fi

# ── Done ──────────────────────────────────────────────────────────────────────

printf '\n%s\n\n' "${BOLD}${GREEN}ClaudeMix installed successfully!${RESET}"

if [[ -n "$SHELL_RC" ]]; then
  printf '  Restart your shell or run:\n'
  printf '    %s\n\n' "${CYAN}source $SHELL_RC${RESET}"
fi

printf '  Then in any git project:\n'
printf '    %s          Generate config\n' "${CYAN}claudemix init${RESET}"
printf '    %s  Set up git hooks\n' "${CYAN}claudemix hooks install${RESET}"
printf '    %s       Start a session\n' "${CYAN}claudemix auth-fix${RESET}"
printf '\n  Docs: %s\n' "${CYAN}https://github.com/Draidel/ClaudeMix${RESET}"
