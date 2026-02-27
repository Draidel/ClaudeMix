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

Each session gets its own git worktree (isolated files), its own branch (`claudemix/<name>`), and optionally its own tmux session (persistence). Git hooks prevent broken code from reaching CI.

## Install

```bash
# Homebrew (recommended)
brew install draidel/claudemix/claudemix

# Or clone and add to PATH
git clone https://github.com/Draidel/ClaudeMix.git ~/.claudemix
echo 'export PATH="$HOME/.claudemix/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Or use the installer
curl -sSL https://raw.githubusercontent.com/Draidel/ClaudeMix/main/install.sh | bash
```

### Dependencies

| Dependency | Required | Purpose | Install |
|-----------|----------|---------|---------|
| [git](https://git-scm.com/) | Yes | Worktree management | Pre-installed on most systems |
| [claude](https://docs.anthropic.com/en/docs/claude-code) | Yes | AI coding sessions | `npm install -g @anthropic-ai/claude-code` |
| [tmux](https://github.com/tmux/tmux) | No | Session persistence (recommended) | `brew install tmux` / `apt install tmux` |
| [gum](https://github.com/charmbracelet/gum) | No | Interactive TUI menus | `brew install gum` / [install guide](https://github.com/charmbracelet/gum#installation) |
| [gh](https://cli.github.com/) | No | Merge queue PR creation | `brew install gh` / [install guide](https://cli.github.com/) |

### Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| macOS (Apple Silicon) | Fully tested | Primary development platform |
| macOS (Intel) | Fully tested | |
| Linux (Ubuntu/Debian) | Supported | Tested on Ubuntu 22.04+ |
| Linux (Fedora/RHEL) | Supported | |
| WSL 2 (Windows) | Supported | Requires bash 4+ |
| Native Windows | Not supported | Use WSL 2 |

**Requirements**: bash 4.0+, git 2.17+ (worktree support)

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

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDEMIX_DEBUG` | `0` | Set to `1` for debug logging |
| `CLAUDEMIX_HOME` | `~/.claudemix` | Override installation directory |
| `NO_COLOR` | `0` | Set to `1` to disable colors |

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

**Pre-commit** (via husky + lint-staged for Node.js, or direct for other projects):
- Runs ESLint on staged files only
- ~2-5 seconds per commit
- Auto-fixes what it can

**Pre-push** (branch guard + validation):
- Blocks direct push to protected branches (main, staging, etc.)
- Runs your project's validate command (lint + type-check)
- Prevents broken code from reaching CI
- POSIX-compatible (works with any `/bin/sh`)

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
3. Creates a merge branch, merges selected work
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
- `package.json` scripts (validate, lint, test) + package manager (pnpm/yarn/bun/npm)
- `Makefile` targets (lint, check)
- `Cargo.toml` (cargo check + clippy)
- `go.mod` (go vet)
- Git remote default branch

## Architecture

```
~/.claudemix/                    # Installation (global)
├── bin/claudemix                # Entry point
├── lib/
│   ├── core.sh                  # Config, logging, utils, pkg detection
│   ├── session.sh               # Session lifecycle (create/attach/kill)
│   ├── worktree.sh              # Git worktree management
│   ├── merge-queue.sh           # Branch consolidation + PR creation
│   ├── hooks.sh                 # Git hooks installer (husky + direct)
│   └── tui.sh                   # Interactive menus (gum + fallback)
├── completions/                 # Shell completions (zsh + bash + fish)
├── tests/                       # Bats test suite (unit + e2e)
├── scripts/                     # Dev scripts (test runner)
├── Formula/                     # Homebrew formula
├── .github/workflows/           # CI (shellcheck + syntax + tests)
└── install.sh                   # curl|bash installer

my-project/                      # Per-project (gitignored)
├── .claudemix.yml               # Project config
└── .claudemix/
    ├── worktrees/               # Git worktrees (one per session)
    │   ├── auth-fix/
    │   └── ui-update/
    └── sessions/                # Session metadata files
        ├── auth-fix.meta
        └── ui-update.meta
```

### Module Responsibilities

| Module | Lines | Responsibility |
|--------|-------|---------------|
| `core.sh` | ~250 | Constants, colors, logging, YAML config parser, package manager detection, dependency checks, utility functions |
| `session.sh` | ~200 | Session CRUD: create (worktree + tmux + claude), attach, list, kill. Array-based command building (no eval). |
| `worktree.sh` | ~180 | Git worktree lifecycle: create, remove, list, cleanup merged. Path validation before rm. |
| `merge-queue.sh` | ~190 | Branch consolidation: select branches, merge, validate, push, create PR via gh. Trap-based cleanup on error. |
| `hooks.sh` | ~200 | Git hooks: husky path (pre-commit + lint-staged) and direct path. POSIX-compatible generated hooks. |
| `tui.sh` | ~230 | Interactive menus via gum with graceful fallback to numbered prompts. |
| `bin/claudemix` | ~150 | Entry point: argument parsing, routing, help. Only file with `set -euo pipefail`. |
| `install.sh` | ~130 | Installer: clone, PATH setup, completions, dependency check. |

### Design Principles

- **Zero hardcoded project knowledge** — all behavior comes from config + auto-detection
- **Works out of the box** — sensible defaults, zero config for basic usage
- **Shell-native** — instant startup, no runtime dependencies beyond bash 4+
- **Graceful degradation** — works without tmux (no persistence), gum (basic prompts), or gh (no merge PRs)
- **Composable** — use just hooks, just sessions, or just merge queue independently
- **Security-conscious** — no eval on user input, path validation before rm, POSIX hooks, sanitized config values
- **Cross-platform** — macOS + Linux, brew + apt install hints, BSD/GNU date handling

### What ClaudeMix Is NOT

- Not a Claude Code fork — it composes on top of Claude's native features
- Not a prompt framework — that's [SuperClaude](https://github.com/SuperClaude-Org/SuperClaude_Framework)'s job
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

### Fish

```fish
# Auto-installed by install.sh and Homebrew, or manually:
cp ~/.claudemix/completions/claudemix.fish ~/.config/fish/completions/
```

## Tips

### Alias for faster typing

```bash
alias cmx="claudemix"
```

### Working with terminal multiplexers

ClaudeMix works great with Ghostty splits, iTerm2 tabs, or any terminal multiplexer. Run `claudemix <name>` in each pane — each gets its own isolated worktree.

### Without tmux

ClaudeMix works without tmux — sessions run in the foreground (no persistence). Install tmux for session persistence: `brew install tmux` (macOS) or `apt install tmux` (Linux).

### Debug mode

```bash
CLAUDEMIX_DEBUG=1 claudemix ls
```

## Roadmap

- [ ] `claudemix status` — dashboard view with session health, branch state, and resource usage
- [ ] `claudemix log <name>` — view Claude session output history
- [ ] `claudemix diff` — show combined diff across all active session branches
- [ ] `claudemix sync` — rebase all session branches onto latest base branch
- [ ] `claudemix export` — export session metadata for team sharing
- [x] Fish shell completions
- [x] Homebrew formula (`brew install draidel/claudemix/claudemix`)
- [ ] Session templates (pre-configured Claude flags + prompts per session type)
- [ ] Integration with Claude Code's native worktree feature
- [ ] Conflict detection (warn before two sessions modify the same files)
- [ ] Resource monitoring (warn when too many sessions are running)
- [ ] GitLab / Bitbucket support for merge queue (currently GitHub-only)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

PRs welcome. Please follow existing code style (shellcheck-clean bash). Key points:

1. All scripts must pass `bash -n` syntax check
2. Library files (`lib/*.sh`) must not use `set -euo pipefail` (entry point handles that)
3. Generated hooks must be POSIX-compatible (`#!/bin/sh`, no bashisms)
4. Never use `eval` on user input — use arrays for command building
5. Cross-platform: test on both macOS and Linux

## License

MIT
