#!/usr/bin/env bash
# ClaudeMix installer
# Usage: curl -sSL https://raw.githubusercontent.com/Draidel/ClaudeMix/main/install.sh | bash

set -euo pipefail

REPO="https://github.com/Draidel/ClaudeMix.git"
INSTALL_DIR="${CLAUDEMIX_HOME:-$HOME/.claudemix}"
BIN_NAME="claudemix"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { echo "${CYAN}info${RESET}  $*"; }
ok()    { echo "${GREEN}ok${RESET}    $*"; }
warn()  { echo "${YELLOW}warn${RESET}  $*" >&2; }
error() { echo "${RED}error${RESET} $*" >&2; }

# ── Pre-flight Checks ───────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
  error "git is required. Install it first."
  exit 1
fi

# ── Install ──────────────────────────────────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]]; then
  info "Updating existing installation at $INSTALL_DIR"
  (cd "$INSTALL_DIR" && git pull --quiet origin main 2>/dev/null) || {
    warn "Git pull failed. Reinstalling..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR" 2>/dev/null
  }
else
  info "Installing ClaudeMix to $INSTALL_DIR"
  git clone --depth 1 "$REPO" "$INSTALL_DIR" 2>/dev/null
fi

chmod +x "$INSTALL_DIR/bin/$BIN_NAME"

# ── Shell Integration ────────────────────────────────────────────────────────

BIN_PATH="$INSTALL_DIR/bin"
SHELL_NAME="$(basename "$SHELL")"
SHELL_RC=""

case "$SHELL_NAME" in
  zsh)  SHELL_RC="$HOME/.zshrc" ;;
  bash)
    if [[ -f "$HOME/.bash_profile" ]]; then
      SHELL_RC="$HOME/.bash_profile"
    else
      SHELL_RC="$HOME/.bashrc"
    fi
    ;;
  fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
esac

# Add to PATH if not already there
if [[ -n "$SHELL_RC" ]]; then
  PATH_LINE="export PATH=\"$BIN_PATH:\$PATH\""

  if [[ "$SHELL_NAME" == "fish" ]]; then
    PATH_LINE="fish_add_path $BIN_PATH"
  fi

  if ! grep -qF "$BIN_PATH" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# ClaudeMix" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    ok "Added $BIN_PATH to PATH in $SHELL_RC"
  else
    info "PATH already configured in $SHELL_RC"
  fi

  # Install completions for zsh
  if [[ "$SHELL_NAME" == "zsh" ]]; then
    local_completions="$HOME/.zsh/completions"
    if [[ -d "$local_completions" ]] || mkdir -p "$local_completions" 2>/dev/null; then
      if [[ -f "$INSTALL_DIR/completions/$BIN_NAME.zsh" ]]; then
        cp "$INSTALL_DIR/completions/$BIN_NAME.zsh" "$local_completions/_$BIN_NAME"
        info "Zsh completions installed"
      fi
    fi
  fi
fi

# ── Check Optional Dependencies ──────────────────────────────────────────────

echo ""
info "Checking optional dependencies..."

missing_optional=()
if ! command -v tmux &>/dev/null; then
  missing_optional+=("tmux (session persistence) — brew install tmux")
fi
if ! command -v gum &>/dev/null; then
  missing_optional+=("gum (interactive TUI) — brew install gum")
fi
if ! command -v gh &>/dev/null; then
  missing_optional+=("gh (merge queue PRs) — brew install gh")
fi
if ! command -v claude &>/dev/null; then
  missing_optional+=("claude (Claude Code CLI) — https://docs.anthropic.com/en/docs/claude-code")
fi

if (( ${#missing_optional[@]} > 0 )); then
  warn "Optional dependencies not found:"
  for dep in "${missing_optional[@]}"; do
    echo "  - $dep"
  done
  echo ""
  info "ClaudeMix works without these but some features will be limited."
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}${GREEN}ClaudeMix installed successfully!${RESET}"
echo ""
echo "  Restart your shell or run:"
echo "    ${CYAN}source $SHELL_RC${RESET}"
echo ""
echo "  Then in any git project:"
echo "    ${CYAN}claudemix init${RESET}          Generate config"
echo "    ${CYAN}claudemix hooks install${RESET}  Set up git hooks"
echo "    ${CYAN}claudemix auth-fix${RESET}       Start a session"
echo ""
echo "  Docs: ${CYAN}https://github.com/Draidel/ClaudeMix${RESET}"
