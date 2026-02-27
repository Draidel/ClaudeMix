#!/usr/bin/env bash
# ClaudeMix — hooks.sh
# Git hooks installation and management.
# Supports husky (preferred) or direct .git/hooks installation.
# Sourced by other modules. Never executed directly.

# ── Hooks Operations ─────────────────────────────────────────────────────────

# Install git hooks for the current project.
# Detects whether to use husky or direct installation.
hooks_install() {
  require_project

  local method="direct"
  if _hooks_should_use_husky; then
    method="husky"
  fi

  log_info "Installing git hooks (${CYAN}$method${RESET} method)"

  case "$method" in
    husky)  _hooks_install_husky ;;
    direct) _hooks_install_direct ;;
  esac

  log_ok "Git hooks installed"
}

# Remove ClaudeMix git hooks from the current project.
hooks_uninstall() {
  require_project

  if [[ -d "$PROJECT_ROOT/.husky" ]]; then
    # Check if we installed husky or if it was pre-existing
    if grep -q "ClaudeMix" "$PROJECT_ROOT/.husky/pre-commit" 2>/dev/null; then
      rm -f "$PROJECT_ROOT/.husky/pre-commit"
      log_ok "Removed .husky/pre-commit"
    fi
    if grep -q "ClaudeMix" "$PROJECT_ROOT/.husky/pre-push" 2>/dev/null; then
      rm -f "$PROJECT_ROOT/.husky/pre-push"
      log_ok "Removed .husky/pre-push"
    fi
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

  echo "${BOLD}Git Hooks Status${RESET}"
  echo ""

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

    printf "  %-14s %b %s\n" "$hook" "$status" "$source"
  done
}

# ── Husky Installation ───────────────────────────────────────────────────────

_hooks_should_use_husky() {
  # Use husky if: it's a Node.js project
  [[ -f "$PROJECT_ROOT/package.json" ]]
}

_hooks_install_husky() {
  local pkg_manager="npm"
  if [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]] || [[ -f "$PROJECT_ROOT/pnpm-workspace.yaml" ]]; then
    pkg_manager="pnpm"
  elif [[ -f "$PROJECT_ROOT/yarn.lock" ]]; then
    pkg_manager="yarn"
  elif [[ -f "$PROJECT_ROOT/bun.lockb" ]]; then
    pkg_manager="bun"
  fi

  # Install husky if not present
  if ! [[ -d "$PROJECT_ROOT/node_modules/husky" ]]; then
    log_info "Installing husky..."
    case "$pkg_manager" in
      pnpm) (cd "$PROJECT_ROOT" && pnpm add -D -w husky 2>/dev/null) ;;
      yarn) (cd "$PROJECT_ROOT" && yarn add -D husky 2>/dev/null) ;;
      bun)  (cd "$PROJECT_ROOT" && bun add -d husky 2>/dev/null) ;;
      npm)  (cd "$PROJECT_ROOT" && npm install -D husky 2>/dev/null) ;;
    esac
  fi

  # Install lint-staged if not present
  if ! [[ -d "$PROJECT_ROOT/node_modules/lint-staged" ]]; then
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

  # Add prepare script if missing
  if ! grep -q '"prepare"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
    log_info "Adding prepare script to package.json..."
    # Use node for reliable JSON manipulation
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('$PROJECT_ROOT/package.json', 'utf8'));
      pkg.scripts = pkg.scripts || {};
      pkg.scripts.prepare = 'husky';
      fs.writeFileSync('$PROJECT_ROOT/package.json', JSON.stringify(pkg, null, 2) + '\n');
    " 2>/dev/null || log_warn "Could not add prepare script automatically"
  fi

  # Write pre-commit hook
  _hooks_write_pre_commit_husky

  # Write pre-push hook
  _hooks_write_pre_push_husky

  # Add lint-staged config if missing
  _hooks_ensure_lint_staged_config
}

_hooks_write_pre_commit_husky() {
  cat > "$PROJECT_ROOT/.husky/pre-commit" << 'HOOK'
# ClaudeMix pre-commit hook — lint staged files
pnpm lint-staged 2>/dev/null || npx lint-staged
HOOK
  chmod +x "$PROJECT_ROOT/.husky/pre-commit"
  log_ok "Created .husky/pre-commit"
}

_hooks_write_pre_push_husky() {
  # Read protected branches from config
  local branches="$CFG_PROTECTED_BRANCHES"

  cat > "$PROJECT_ROOT/.husky/pre-push" << HOOK
# ClaudeMix pre-push hook — branch guard + validation

# ── Branch Guard ──
branch=\$(git symbolic-ref --short HEAD 2>/dev/null)
protected_branches="${branches}"

IFS=',' read -ra BRANCHES <<< "\$protected_branches"
for protected in "\${BRANCHES[@]}"; do
  protected=\$(echo "\$protected" | tr -d '[:space:]')
  if [ "\$branch" = "\$protected" ]; then
    echo "❌ Direct push to '\$branch' is blocked by ClaudeMix."
    echo "   Create a feature branch: git checkout -b fix/description"
    exit 1
  fi
done

# ── Validation ──
HOOK

  # Add validate command if configured
  if [[ -n "$CFG_VALIDATE" ]]; then
    cat >> "$PROJECT_ROOT/.husky/pre-push" << HOOK
echo "🔍 Running validation before push..."
$CFG_VALIDATE
HOOK
  fi

  chmod +x "$PROJECT_ROOT/.husky/pre-push"
  log_ok "Created .husky/pre-push (guards: $branches)"
}

_hooks_ensure_lint_staged_config() {
  # Check if lint-staged config already exists
  if grep -q '"lint-staged"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
    log_debug "lint-staged config already in package.json"
    return 0
  fi
  if [[ -f "$PROJECT_ROOT/.lintstagedrc" ]] || \
     [[ -f "$PROJECT_ROOT/.lintstagedrc.json" ]] || \
     [[ -f "$PROJECT_ROOT/.lintstagedrc.yml" ]] || \
     [[ -f "$PROJECT_ROOT/lint-staged.config.js" ]] || \
     [[ -f "$PROJECT_ROOT/lint-staged.config.mjs" ]]; then
    log_debug "lint-staged config file already exists"
    return 0
  fi

  # Auto-detect and add lint-staged config to package.json
  log_info "Adding lint-staged configuration..."

  local lint_cmd="eslint --fix"
  local format_cmd="prettier --write"
  local ts_glob='*.{ts,tsx}'
  local style_glob='*.{json,md,yml,yaml}'

  # Check if eslint flat config exists
  if [[ -f "$PROJECT_ROOT/eslint.config.mjs" ]] || [[ -f "$PROJECT_ROOT/eslint.config.js" ]]; then
    lint_cmd="eslint --fix --no-warn-ignored"
  fi

  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('$PROJECT_ROOT/package.json', 'utf8'));
    pkg['lint-staged'] = {
      '$ts_glob': '$lint_cmd',
      '$style_glob': '$format_cmd'
    };
    fs.writeFileSync('$PROJECT_ROOT/package.json', JSON.stringify(pkg, null, 2) + '\n');
  " 2>/dev/null || log_warn "Could not add lint-staged config automatically"

  log_ok "lint-staged config added to package.json"
}

# ── Direct Installation (non-Node projects) ──────────────────────────────────

_hooks_install_direct() {
  local hooks_dir
  hooks_dir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir)/hooks"
  mkdir -p "$hooks_dir"

  # Pre-commit (basic — no lint-staged)
  if [[ -n "$CFG_VALIDATE" ]]; then
    cat > "$hooks_dir/pre-commit" << HOOK
#!/bin/sh
# ClaudeMix pre-commit hook
echo "🔍 Running pre-commit validation..."
$CFG_VALIDATE
HOOK
    chmod +x "$hooks_dir/pre-commit"
    log_ok "Created pre-commit hook"
  fi

  # Pre-push (branch guard + validate)
  local branches="$CFG_PROTECTED_BRANCHES"
  cat > "$hooks_dir/pre-push" << HOOK
#!/bin/sh
# ClaudeMix pre-push hook — branch guard + validation

branch=\$(git symbolic-ref --short HEAD 2>/dev/null)
protected_branches="${branches}"

IFS=',' read -ra BRANCHES <<< "\$protected_branches"
for protected in "\${BRANCHES[@]}"; do
  protected=\$(echo "\$protected" | tr -d '[:space:]')
  if [ "\$branch" = "\$protected" ]; then
    echo "❌ Direct push to '\$branch' is blocked by ClaudeMix."
    echo "   Create a feature branch: git checkout -b fix/description"
    exit 1
  fi
done
HOOK

  if [[ -n "$CFG_VALIDATE" ]]; then
    cat >> "$hooks_dir/pre-push" << HOOK

echo "🔍 Running validation before push..."
$CFG_VALIDATE
HOOK
  fi

  chmod +x "$hooks_dir/pre-push"
  log_ok "Created pre-push hook (guards: $branches)"
}
