# ClaudeMix

Multi-session orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Run multiple Claude instances in parallel with proper isolation, lifecycle management, and work consolidation.

## The Problem

Claude Code is single-session by design. Power users running 5-10+ sessions simultaneously hit:

- **File conflicts** — sessions overwrite each other's work
- **Branch chaos** — `git checkout` in one session breaks another
- **CI churn** — 8 sessions = 8 PRs = 8 CI runs = wasted time
- **Session blindness** — no way to see what's running or manage it

## The Solution

ClaudeMix adds the orchestration layer:

```
claudemix auth-fix       # Isolated session in its own worktree + tmux
claudemix ui-update      # Another isolated session, running in parallel
claudemix ls             # See what's running
claudemix merge          # Bundle finished work into one PR
```

Each session gets its own git worktree (isolated files), its own branch (`claudemix/<name>`), and optionally its own tmux session (persistence). Git hooks prevent broken code from ever reaching CI.

## Install

```bash
# Clone and add to PATH
git clone https://github.com/Draidel/ClaudeMix.git ~/.claudemix
echo 'export PATH="$HOME/.claudemix/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Or use the installer
curl -sSL https://raw.githubusercontent.com/Draidel/ClaudeMix/main/install.sh | bash
```

### Dependencies

| Dependency | Required | Purpose |
|-----------|----------|---------|
| git | Yes | Worktree management |
| [claude](https://docs.anthropic.com/en/docs/claude-code) | Yes | AI coding sessions |
| [tmux](https://github.com/tmux/tmux) | No | Session persistence (recommended) |
| [gum](https://github.com/charmbracelet/gum) | No | Interactive TUI menus |
| [gh](https://cli.github.com/) | No | Merge queue PR creation |

```bash
# Install optional dependencies (macOS)
brew install tmux gum gh
```

## Quick Start

```bash
# In any git project
cd my-project

# Generate config (auto-detects your setup)
claudemix init

# Install git hooks (pre-commit lint + pre-push validation)
claudemix hooks install

# Start working
claudemix auth-fix          # Creates worktree + launches Claude
claudemix ui-update         # Another parallel session
claudemix ls                # See active sessions
claudemix merge             # Consolidate into one PR when done
claudemix cleanup           # Remove merged worktrees
```

## Commands

### Sessions

| Command | Description |
|---------|-------------|
| `claudemix` | Interactive TUI menu |
| `claudemix <name>` | Create or attach to a named session |
| `claudemix <name> [flags]` | Create session with extra Claude flags |
| `claudemix ls` | List active sessions with status |
| `claudemix kill <name>` | Kill a session (keeps branch for merge) |
| `claudemix kill all` | Kill all sessions |

### Merge Queue

| Command | Description |
|---------|-------------|
| `claudemix merge` | Select branches and consolidate into one PR |
| `claudemix merge list` | Show branches eligible for merge |

### Maintenance

| Command | Description |
|---------|-------------|
| `claudemix cleanup` | Remove worktrees for merged branches |
| `claudemix hooks install` | Install pre-commit + pre-push hooks |
| `claudemix hooks uninstall` | Remove ClaudeMix hooks |
| `claudemix hooks status` | Show current hook status |
| `claudemix init` | Generate `.claudemix.yml` config |

## How It Works

### Session Lifecycle

```
claudemix auth-fix
    │
    ├── 1. Creates git worktree: .claudemix/worktrees/auth-fix
    │      Branch: claudemix/auth-fix (from base branch)
    │
    ├── 2. Installs dependencies (pnpm/yarn/npm — uses shared store, fast)
    │
    ├── 3. Creates tmux session: claudemix-auth-fix
    │      (or runs directly if tmux not available)
    │
    └── 4. Launches Claude Code in the worktree
           (isolated files, isolated branch, isolated terminal)
```

### Git Hooks

**Pre-commit** (via husky + lint-staged):
- Runs ESLint on staged files only
- ~2-5 seconds per commit
- Auto-fixes what it can

**Pre-push** (branch guard + validation):
- Blocks direct push to protected branches (main, staging, etc.)
- Runs your project's validate command (lint + type-check)
- Prevents broken code from reaching CI

### Merge Queue

Instead of 8 PRs from 8 sessions:

```
claudemix/auth-fix       ─┐
claudemix/ui-update      ─┤
claudemix/api-refactor   ─┼──→  claudemix/merge-20260227  ──→  Single PR
claudemix/perf-optimize  ─┤
claudemix/bug-fix        ─┘
```

1. `claudemix merge` shows all session branches
2. You select which ones to consolidate
3. Creates a merge branch, cherry-picks selected work
4. Runs validation on the consolidated result
5. Creates a single PR with auto-merge enabled

## Configuration

Drop `.claudemix.yml` in your project root:

```yaml
# Command to validate code before push (auto-detected)
validate: pnpm validate

# Branches blocked from direct push (comma-separated)
protected_branches: main,staging

# Target branch for merge queue PRs
merge_target: staging

# Merge strategy: squash, merge, or rebase
merge_strategy: squash

# Base branch for new worktrees
base_branch: staging

# Extra flags for Claude Code
claude_flags: --dangerously-skip-permissions --verbose
```

All values are optional. ClaudeMix auto-detects defaults from:
- `package.json` scripts (validate, lint, test)
- `Makefile` targets
- `Cargo.toml` / `go.mod`
- Git remote default branch

## Architecture

```
~/.claudemix/                    # Installation (global)
├── bin/claudemix                # Entry point
├── lib/
│   ├── core.sh                  # Config, logging, utils
│   ├── session.sh               # Session lifecycle
│   ├── worktree.sh              # Git worktree management
│   ├── merge-queue.sh           # Branch consolidation
│   ├── hooks.sh                 # Git hooks installer
│   └── tui.sh                   # Interactive menus (gum)
├── completions/                 # Shell completions
└── install.sh                   # Installer

my-project/                      # Per-project (gitignored)
├── .claudemix.yml               # Project config
└── .claudemix/
    ├── worktrees/               # Git worktrees
    │   ├── auth-fix/
    │   └── ui-update/
    └── sessions/                # Session metadata
        ├── auth-fix.meta
        └── ui-update.meta
```

### Design Principles

- **Zero hardcoded project knowledge** — all behavior from config
- **Works out of the box** — sensible defaults, zero config for basic usage
- **Shell-native** — instant startup, no runtime dependencies beyond bash
- **Graceful degradation** — works without tmux, gum, or gh (with reduced features)
- **Composable** — use just hooks, just sessions, or just merge queue independently

### What ClaudeMix Is NOT

- Not a Claude Code fork — it composes on top of Claude's native features
- Not a prompt framework (that's [SuperClaude](https://github.com/SuperClaude-Org/SuperClaude_Framework)'s job)
- Not a CI/CD tool — that's GitHub Actions' job

### Layer Model

```
┌─────────────────────────────────────────────────┐
│  Developer                                       │
├─────────────────────────────────────────────────┤
│  ClaudeMix    — Session orchestration            │  ← THIS
│                 (isolation, lifecycle, merging)   │
├─────────────────────────────────────────────────┤
│  SuperClaude  — Prompt intelligence (optional)   │
│                 (personas, skills, modes)         │
├─────────────────────────────────────────────────┤
│  Claude Code  — AI coding runtime                │
│                 (tools, MCP, context)             │
├─────────────────────────────────────────────────┤
│  Git + GitHub — Version control & CI             │
└─────────────────────────────────────────────────┘
```

## Shell Completions

### Zsh

```bash
# Auto-installed by install.sh, or manually:
mkdir -p ~/.zsh/completions
cp ~/.claudemix/completions/claudemix.zsh ~/.zsh/completions/_claudemix
# Add to .zshrc: fpath=(~/.zsh/completions $fpath)
```

### Bash

```bash
source ~/.claudemix/completions/claudemix.bash
# Or add to .bashrc
```

## Tips

### Alias for faster typing

```bash
alias cmx="claudemix"
```

### Replacing an existing `claudev` alias

If you currently have `alias claudev="claude --dangerously-skip-permissions --verbose"`, replace it:

```bash
# Remove old alias, add claudemix to PATH
# Your claude_flags in .claudemix.yml handles the --dangerously-skip-permissions flag
```

### Working with Ghostty splits

ClaudeMix works great with terminal multiplexers. Run `claudemix <name>` in each Ghostty split — each gets its own isolated worktree.

### Without tmux

ClaudeMix works without tmux. Sessions run in the foreground (no persistence). Install tmux for session persistence: `brew install tmux`.

## Contributing

PRs welcome. Please follow existing code style (shellcheck-clean bash).

## License

MIT
