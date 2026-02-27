# shellcheck shell=bash
# ClaudeMix — hooks.sh
# Git hooks installation and management.
# Supports husky (preferred for Node.js projects) or direct .git/hooks.
# Sourced by bin/claudemix. Never executed directly.

# ── Hooks Operations ─────────────────────────────────────────────────────────

# Install git hooks for the current project.
hooks_install() {
  require_project

  local method="direct"
  if [[ -f "$PROJECT_ROOT/package.json" ]]; then
    method="husky"
  fi

  log_info "Installing git hooks (${CYAN}$method${RESET} method)"

  case "$method" in
    husky)  _hooks_install_husky ;;
    direct) _hooks_install_direct ;;
  esac

  log_ok "Git hooks installed"
}

# Remove ClaudeMix git hooks.
hooks_uninstall() {
  require_project

  if [[ -d "$PROJECT_ROOT/.husky" ]]; then
    for hook in pre-commit pre-push; do
      if [[ -f "$PROJECT_ROOT/.husky/$hook" ]] && grep -q "ClaudeMix" "$PROJECT_ROOT/.husky/$hook" 2>/dev/null; then
        rm -f "$PROJECT_ROOT/.husky/$hook"
        log_ok "Removed .husky/$hook"
      fi
    done
  fi

  local hooks_dir
  hooks_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir)/hooks"
  for hook in pre-commit pre-push; do
    if [[ -f "$hooks_dir/$hook" ]] && grep -q "ClaudeMix" "$hooks_dir/$hook" 2>/dev/null; then
      rm -f "$hooks_dir/$hook"
      log_ok "Removed $hook hook"
    fi
  done

  log_ok "Hooks uninstalled"
}

# Show current hook status.
hooks_status() {
  require_project

  local hooks_dir
  hooks_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir)/hooks"
  local husky_dir="$PROJECT_ROOT/.husky"

  printf '%s\n\n' "${BOLD}Git Hooks Status${RESET}"

  for hook in pre-commit pre-push; do
    local status="${RED}not installed${RESET}"
    local source=""

    if [[ -f "$husky_dir/$hook" ]]; then
      status="${GREEN}installed${RESET}"
      source="(husky)"
      if grep -q "ClaudeMix" "$husky_dir/$hook" 2>/dev/null; then
        source="(husky, ClaudeMix)"
      fi
    elif [[ -f "$hooks_dir/$hook" ]]; then
      status="${GREEN}installed${RESET}"
      source="(direct)"
      if grep -q "ClaudeMix" "$hooks_dir/$hook" 2>/dev/null; then
        source="(direct, ClaudeMix)"
      fi
    fi

    printf '  %-14s %b %s\n' "$hook" "$status" "$source"
  done
}

# ── Husky Installation ───────────────────────────────────────────────────────

_hooks_install_husky() {
  local pkg_manager
  pkg_manager="$(detect_pkg_manager "$PROJECT_ROOT")"

  # Install husky if not present
  if [[ ! -d "$PROJECT_ROOT/node_modules/husky" ]]; then
    log_info "Installing husky..."
    case "$pkg_manager" in
      pnpm) (cd "$PROJECT_ROOT" && pnpm add -D -w husky 2>/dev/null) ;;
      yarn) (cd "$PROJECT_ROOT" && yarn add -D husky 2>/dev/null) ;;
      bun)  (cd "$PROJECT_ROOT" && bun add -d husky 2>/dev/null) ;;
      npm)  (cd "$PROJECT_ROOT" && npm install -D husky 2>/dev/null) ;;
    esac
  fi

  # Install lint-staged if not present
  if [[ ! -d "$PROJECT_ROOT/node_modules/lint-staged" ]]; then
    log_info "Installing lint-staged..."
    case "$pkg_manager" in
      pnpm) (cd "$PROJECT_ROOT" && pnpm add -D -w lint-staged 2>/dev/null) ;;
      yarn) (cd "$PROJECT_ROOT" && yarn add -D lint-staged 2>/dev/null) ;;
      bun)  (cd "$PROJECT_ROOT" && bun add -d lint-staged 2>/dev/null) ;;
      npm)  (cd "$PROJECT_ROOT" && npm install -D lint-staged 2>/dev/null) ;;
    esac
  fi

  # Initialize husky
  log_info "Initializing husky..."
  (cd "$PROJECT_ROOT" && npx husky init 2>/dev/null) || true
  mkdir -p "$PROJECT_ROOT/.husky"

  # Add prepare script if missing (using stdin to avoid path injection)
  if ! grep -q '"prepare"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
    log_info "Adding prepare script to package.json..."
    (cd "$PROJECT_ROOT" && node << 'NODESCRIPT'
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts = pkg.scripts || {};
pkg.scripts.prepare = 'husky';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
NODESCRIPT
    ) 2>/dev/null || log_warn "Could not add prepare script automatically"
  fi

  _hooks_write_pre_commit_husky
  _hooks_write_pre_push "$PROJECT_ROOT/.husky/pre-push"
  _hooks_ensure_lint_staged_config
}

# Write the pre-commit hook for husky.
_hooks_write_pre_commit_husky() {
  cat > "$PROJECT_ROOT/.husky/pre-commit" << 'HOOK'
# ClaudeMix pre-commit hook — lint staged files
pnpm lint-staged 2>/dev/null || npx lint-staged
HOOK
  chmod +x "$PROJECT_ROOT/.husky/pre-commit"
  log_ok "Created .husky/pre-commit"
}

# Write a POSIX-compatible pre-push hook to a given path.
# Uses the current CFG_PROTECTED_BRANCHES and CFG_VALIDATE values.
# Args: $1 = output path
_hooks_write_pre_push() {
  local output_path="$1"

  # Sanitize protected branches (only safe chars: alphanumeric, commas, hyphens, underscores, slashes, dots)
  local safe_branches
  safe_branches="$(printf '%s' "$CFG_PROTECTED_BRANCHES" | tr -cd 'a-zA-Z0-9,_./-')"

  # Write POSIX-compatible hook (no bash arrays, no bashisms)
  cat > "$output_path" << 'HOOKHEAD'
#!/bin/sh
# ClaudeMix pre-push hook — branch guard + validation

branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ -z "$branch" ]; then
  exit 0
fi

HOOKHEAD

  # Embed the protected branches as a literal string
  printf 'protected_branches="%s"\n\n' "$safe_branches" >> "$output_path"

  cat >> "$output_path" << 'HOOKGUARD'
# POSIX-compatible branch guard (no bash arrays needed)
OLD_IFS="$IFS"
IFS=','
for p in $protected_branches; do
  IFS="$OLD_IFS"
  p=$(echo "$p" | tr -d '[:space:]')
  if [ "$branch" = "$p" ]; then
    echo "Error: Direct push to '$branch' is blocked by ClaudeMix."
    echo "  Create a feature branch: git checkout -b fix/description"
    exit 1
  fi
done
IFS="$OLD_IFS"
HOOKGUARD

  # Append validate command if configured
  if [[ -n "$CFG_VALIDATE" ]]; then
    printf '\necho "Running validation before push..."\n' >> "$output_path"
    printf '%s\n' "$CFG_VALIDATE" >> "$output_path"
  fi

  chmod +x "$output_path"
  log_ok "Created pre-push hook (guards: $safe_branches)"
}

# Ensure a lint-staged configuration exists.
_hooks_ensure_lint_staged_config() {
  # Check all known config locations
  if grep -q '"lint-staged"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
    log_debug "lint-staged config already in package.json"
    return 0
  fi
  for cfg in .lintstagedrc .lintstagedrc.json .lintstagedrc.yml lint-staged.config.js lint-staged.config.mjs; do
    if [[ -f "$PROJECT_ROOT/$cfg" ]]; then
      log_debug "lint-staged config file already exists: $cfg"
      return 0
    fi
  done

  log_info "Adding lint-staged configuration..."

  local lint_cmd="eslint --fix"
  # Detect flat config
  if [[ -f "$PROJECT_ROOT/eslint.config.mjs" ]] || [[ -f "$PROJECT_ROOT/eslint.config.js" ]]; then
    lint_cmd="eslint --fix --no-warn-ignored"
  fi

  # Use stdin-based node script to avoid path injection
  (cd "$PROJECT_ROOT" && LINT_CMD="$lint_cmd" node << 'NODESCRIPT'
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg['lint-staged'] = {
  '*.{ts,tsx}': process.env.LINT_CMD || 'eslint --fix',
  '*.{json,md,yml,yaml}': 'prettier --write'
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
NODESCRIPT
  ) 2>/dev/null || log_warn "Could not add lint-staged config automatically"

  log_ok "lint-staged config added to package.json"
}

# ── Direct Installation (non-Node projects) ──────────────────────────────────

_hooks_install_direct() {
  local hooks_dir
  hooks_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir)/hooks"
  mkdir -p "$hooks_dir"

  # Pre-commit hook (basic — no lint-staged)
  if [[ -n "$CFG_VALIDATE" ]]; then
    cat > "$hooks_dir/pre-commit" << 'HOOK'
#!/bin/sh
# ClaudeMix pre-commit hook
echo "Running pre-commit validation..."
HOOK
    printf '%s\n' "$CFG_VALIDATE" >> "$hooks_dir/pre-commit"
    chmod +x "$hooks_dir/pre-commit"
    log_ok "Created pre-commit hook"
  fi

  # Pre-push hook (POSIX-compatible branch guard + validate)
  _hooks_write_pre_push "$hooks_dir/pre-push"
}
