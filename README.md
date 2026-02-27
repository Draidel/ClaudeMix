<p align="center">
  <h1 align="center">ClaudeMix</h1>
  <p align="center">
    Multi-session orchestrator for <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a>
    <br />
    Run parallel Claude sessions with full isolation, lifecycle management, and a merge queue.
    <br />
    <br />
    <a href="https://github.com/Draidel/ClaudeMix/releases"><img src="https://img.shields.io/github/v/release/Draidel/ClaudeMix?label=version&color=blue" alt="Version" /></a>
    <a href="https://github.com/Draidel/ClaudeMix/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT" /></a>
    <a href="https://github.com/Draidel/ClaudeMix/actions"><img src="https://img.shields.io/github/actions/workflow/status/Draidel/ClaudeMix/ci.yml?label=CI" alt="CI" /></a>
    <a href="https://github.com/Draidel/ClaudeMix/stargazers"><img src="https://img.shields.io/github/stars/Draidel/ClaudeMix?style=flat&color=yellow" alt="Stars" /></a>
    <br />
    <br />
    <a href="#install">Install</a>
    &middot;
    <a href="#quick-start">Quick Start</a>
    &middot;
    <a href="#commands">Commands</a>
    &middot;
    <a href="#configuration">Configuration</a>
    &middot;
    <a href="#how-it-works">How It Works</a>
  </p>
</p>

<br />

> [!WARNING]
> **Alpha software** — ClaudeMix is under active development and not yet feature-complete. Things may break, APIs may change, and there are rough edges. That said, it works and I use it daily. Bug reports and PRs are very welcome!

> [!NOTE]
> If you find ClaudeMix useful, please consider giving it a :star: — it really helps and means a lot for a solo project. Thank you to everyone who has starred, shared, or contributed!

## Why ClaudeMix?

Claude Code is single-session by design. When you run 5-10+ sessions simultaneously, things break:

| Problem | What happens |
|---------|-------------|
| **File conflicts** | Sessions overwrite each other's work |
| **Branch chaos** | `git checkout` in one session breaks another |
| **CI churn** | 8 sessions = 8 PRs = 8 CI runs = wasted compute |
| **Session blindness** | No visibility into what's running or where |

ClaudeMix solves all of this with one command:

```bash
claudemix auth-fix       # Isolated worktree + branch + tmux + Claude
claudemix ui-update      # Another one, fully parallel
claudemix ls             # See everything at a glance
claudemix merge          # Bundle finished work into a single PR
```

Every session gets its own git worktree (isolated files), its own branch (`claudemix/<name>`), and optionally its own tmux session (persistence). No conflicts. No chaos.

## Install

### Homebrew (recommended)

```bash
brew install draidel/claudemix/claudemix
```

### curl installer

```bash
curl -sSL https://raw.githubusercontent.com/Draidel/ClaudeMix/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/Draidel/ClaudeMix.git ~/.claudemix
echo 'export PATH="$HOME/.claudemix/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Dependencies

| Dependency | Required | Purpose | Install |
|-----------|----------|---------|---------|
| [git](https://git-scm.com/) 2.17+ | **Yes** | Worktree management | Pre-installed on most systems |
| [claude](https://docs.anthropic.com/en/docs/claude-code) | **Yes** | AI coding sessions | `npm i -g @anthropic-ai/claude-code` |
| [tmux](https://github.com/tmux/tmux) | No | Session persistence | `brew install tmux` / `apt install tmux` |
| [gum](https://github.com/charmbracelet/gum) | No | Interactive TUI menus | `brew install gum` / [install guide](https://github.com/charmbracelet/gum#installation) |
| [gh](https://cli.github.com/) | No | PR creation in merge queue | `brew install gh` / [install guide](https://cli.github.com/) |

**Requirements**: bash 4.0+, git 2.17+ (worktree support)

### Platform Support

| Platform | Status |
|----------|--------|
| macOS (Apple Silicon / Intel) | :white_check_mark: Fully tested |
| Linux (Ubuntu, Debian, Fedora, RHEL) | :white_check_mark: Supported |
| WSL 2 | :white_check_mark: Supported (bash 4+) |
| Native Windows | :x: Not supported — use WSL 2 |

## Quick Start

```bash
cd my-project                      # Any git repository

claudemix init                     # Generate config (auto-detects your stack)
claudemix hooks install            # Install pre-commit + pre-push hooks

claudemix auth-fix                 # Session 1: isolated worktree + Claude
claudemix ui-update                # Session 2: another parallel session
claudemix api-refactor             # Session 3: and another

claudemix ls                       # See all active sessions
claudemix kill auth-fix            # Done with one? Kill it (branch kept)
claudemix merge                    # Consolidate branches into one PR
claudemix cleanup                  # Remove merged worktrees
```

## Commands

### Sessions

```
claudemix                          Interactive TUI menu
claudemix <name>                   Create or attach to a named session
claudemix <name> [claude-flags]    Create session with extra Claude flags
claudemix ls                       List active sessions with status
claudemix kill <name>              Kill a session (keeps branch for merge)
claudemix kill all                 Kill all sessions
```

### Merge Queue

```
claudemix merge                    Select branches → consolidate → create PR
claudemix merge list               Show branches eligible for merge
```

### Maintenance

```
claudemix cleanup                  Remove worktrees for merged branches
claudemix hooks install            Install pre-commit + pre-push hooks
claudemix hooks uninstall          Remove ClaudeMix hooks
claudemix hooks status             Show current hook status
claudemix init                     Generate .claudemix.yml config
claudemix version                  Show version
claudemix help                     Show help
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLAUDEMIX_DEBUG` | `0` | Set to `1` for debug logging |
| `CLAUDEMIX_HOME` | `~/.claudemix` | Override installation directory |
| `NO_COLOR` | `0` | Set to `1` to disable colors |

## How It Works

### Session Lifecycle

```
claudemix auth-fix
    │
    ├── 1. Create git worktree     .claudemix/worktrees/auth-fix
    │      New branch:             claudemix/auth-fix (from base branch)
    │
    ├── 2. Install dependencies    Auto-detects pnpm/yarn/bun/npm
    │
    ├── 3. Create tmux session     claudemix-auth-fix
    │      (foreground if no tmux)
    │
    └── 4. Launch Claude Code      Isolated files, branch, and terminal
```

Rerunning `claudemix auth-fix` attaches to the existing session instead of creating a new one.

### Merge Queue

Instead of N sessions creating N PRs with N CI runs:

```
claudemix/auth-fix       ─┐
claudemix/ui-update      ─┤
claudemix/api-refactor   ─┼──→  claudemix/merge-20260227  ──→  Single PR
claudemix/perf-optimize  ─┤
claudemix/bug-fix        ─┘
```

1. `claudemix merge` lists all session branches with commits ahead of target
2. Select which branches to consolidate (interactive menu or numbered list)
3. Creates a merge branch, merges selected work sequentially
4. Runs your project's validation command on the result
5. Pushes and creates a PR via `gh` with auto-merge enabled
6. Branches that conflict are skipped and reported

### Git Hooks

ClaudeMix installs two hooks:

**Pre-commit** — Fast feedback on staged files:
- Node.js projects: husky + lint-staged (ESLint on changed files only)
- Other projects: runs your linter directly
- ~2-5 seconds per commit

**Pre-push** — Gate before CI:
- Blocks direct push to protected branches (main, staging, etc.)
- Runs your `validate` command (lint + type-check + tests)
- Generated hooks are POSIX `#!/bin/sh` — work everywhere

## Configuration

Create `.claudemix.yml` in your project root (or run `claudemix init`):

```yaml
# Command to validate code before push (auto-detected)
validate: pnpm validate

# Branches blocked from direct push (comma-separated)
protected_branches: main,staging

# Target branch for merge queue PRs
merge_target: staging

# Merge strategy: squash | merge | rebase
merge_strategy: squash

# Base branch for new worktrees
base_branch: staging

# Directory for worktrees (relative to project root)
worktree_dir: .claudemix/worktrees

# Extra flags for Claude Code
claude_flags: --dangerously-skip-permissions --verbose
```

**All values are optional.** ClaudeMix auto-detects sensible defaults:

| Source | Detected |
|--------|----------|
| `package.json` | validate/lint/test scripts + package manager (pnpm/yarn/bun/npm) |
| `Makefile` | lint/check targets |
| `Cargo.toml` | `cargo check && cargo clippy` |
| `go.mod` | `go vet ./...` |
| Git remote | Default branch (main/master/staging/develop) |

## Architecture

```
bin/claudemix                Entry point (set -euo pipefail, arg parsing, routing)
lib/
├── core.sh                  Constants, colors, logging, YAML config, pkg detection, utils
├── session.sh               Session CRUD: create, attach, list, kill (tmux + worktree)
├── worktree.sh              Git worktree management: create, remove, list, cleanup
├── merge-queue.sh           Branch consolidation: select, merge, validate, push, PR
├── hooks.sh                 Git hooks installer (husky path + direct path)
└── tui.sh                   Interactive menus (gum with basic prompt fallback)
completions/                 Shell completions (bash + zsh + fish)
tests/                       Bats test suite (unit + e2e)
install.sh                   curl|bash installer
Formula/                     Homebrew formula
```

### Per-Project Structure

```
my-project/
├── .claudemix.yml                  Project config
└── .claudemix/                     Session data (gitignored)
    ├── worktrees/                  Git worktrees (one per session)
    │   ├── auth-fix/
    │   └── ui-update/
    └── sessions/                   Session metadata
        ├── auth-fix.meta
        └── ui-update.meta
```

### Design Principles

- **Zero config** — works out of the box with auto-detected defaults
- **Shell-native** — instant startup, ~2K lines of bash, no runtime dependencies
- **Graceful degradation** — works without tmux (no persistence), gum (basic prompts), gh (no PR creation)
- **Security-conscious** — no `eval` on user input, config validation, path guards before `rm -rf`, POSIX hooks
- **Composable** — use sessions, hooks, or merge queue independently
- **Cross-platform** — macOS + Linux, BSD/GNU date handling, brew + apt install hints

### Where ClaudeMix Fits

```
┌─────────────────────────────────────────────────┐
│  Developer                                       │
├─────────────────────────────────────────────────┤
│  ClaudeMix    — Session orchestration            │  ◄── this
│                 (isolation, lifecycle, merging)   │
├─────────────────────────────────────────────────┤
│  Claude Code  — AI coding runtime                │
│                 (tools, MCP, context)             │
├─────────────────────────────────────────────────┤
│  Git + GitHub — Version control & CI             │
└─────────────────────────────────────────────────┘
```

ClaudeMix is **not** a Claude Code fork, a prompt framework, or a CI/CD tool. It's the orchestration layer between you and multiple Claude Code sessions.

## Shell Completions

Completions are installed automatically by `install.sh` and Homebrew.

<details>
<summary>Manual installation</summary>

**Zsh**
```bash
mkdir -p ~/.zsh/completions
cp ~/.claudemix/completions/claudemix.zsh ~/.zsh/completions/_claudemix
# Add to .zshrc: fpath=(~/.zsh/completions $fpath)
```

**Bash**
```bash
mkdir -p ~/.local/share/bash-completion/completions
cp ~/.claudemix/completions/claudemix.bash ~/.local/share/bash-completion/completions/claudemix
```

**Fish**
```bash
cp ~/.claudemix/completions/claudemix.fish ~/.config/fish/completions/
```

</details>

## Tips

**Alias for faster typing:**

```bash
alias cmx="claudemix"
```

**Works with any terminal setup** — Ghostty splits, iTerm2 tabs, Warp, Alacritty. Run `claudemix <name>` in each pane for fully isolated sessions.

**Without tmux** — Sessions run in the foreground (no persistence). Install tmux for background session support.

**Debug mode:**

```bash
CLAUDEMIX_DEBUG=1 claudemix ls
```

## Roadmap

> [!NOTE]
> ClaudeMix is in **alpha**. The core works and is used daily, but there's a lot more planned. PRs for any of these are especially welcome!

- [ ] `claudemix status` — dashboard with session health, branch state, resource usage
- [ ] `claudemix log <name>` — view Claude session output history
- [ ] `claudemix diff` — combined diff across all active sessions
- [ ] `claudemix sync` — rebase all session branches onto latest base
- [ ] Session templates — pre-configured Claude flags + prompts per session type
- [ ] Conflict detection — warn when two sessions modify the same files
- [ ] Resource monitoring — warn when too many sessions are running
- [ ] GitLab / Bitbucket merge queue support

## Contributing

> [!TIP]
> This is a solo open-source project and contributions mean the world. Whether it's a bug report, a feature idea, a docs fix, or a PR — thank you. Seriously. :heart:

PRs welcome. Please follow existing code style (shellcheck-clean bash).

1. All scripts must pass `bash -n` syntax check and `shellcheck`
2. Library files (`lib/*.sh`) must not contain `set -euo pipefail`
3. Generated hooks must be POSIX-compatible (`#!/bin/sh`, no bashisms)
4. Never use `eval` on user input — use arrays for command building
5. Use `printf` instead of `echo` for portability
6. Test on both macOS and Linux

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=Draidel/ClaudeMix&type=date&legend=top-left)](https://www.star-history.com/#Draidel/ClaudeMix&type=date&legend=top-left)

## License

[MIT](LICENSE) — built with :heart: and way too many Claude Code sessions.
