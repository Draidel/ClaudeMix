# Contributing to ClaudeMix

Thanks for your interest in contributing! ClaudeMix is a community-driven project and we welcome contributions of all kinds.

## Getting Started

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/ClaudeMix.git
cd ClaudeMix

# Test your setup
bash bin/claudemix version
bash bin/claudemix help

# Run syntax checks
for f in bin/claudemix lib/*.sh install.sh; do bash -n "$f" && echo "$f OK"; done
```

## Development Workflow

1. **Create a branch** from `main`:
   ```bash
   git checkout -b feat/your-feature
   ```

2. **Make your changes** following the code style guide below.

3. **Test locally**:
   ```bash
   # Syntax check
   bash -n bin/claudemix
   bash -n lib/your-changed-file.sh

   # Functional test from any git project
   cd /path/to/test-project
   /path/to/ClaudeMix/bin/claudemix version
   /path/to/ClaudeMix/bin/claudemix hooks status
   /path/to/ClaudeMix/bin/claudemix ls
   ```

4. **Submit a PR** to `main`.

## Code Style

### Bash Conventions

- **bash 4.0+** required. Use bash features (arrays, `[[ ]]`, `${var//pattern/}`) in library code.
- **POSIX sh** required for generated hooks only (they use `#!/bin/sh`).
- **Naming**: `snake_case` for functions/variables, `UPPER_CASE` for constants.
- **Private functions**: prefix with `_` (e.g., `_session_launch_tmux`).
- **Output**: use `printf` instead of `echo` for portability.
- **Logging**: use `log_info`, `log_ok`, `log_warn`, `log_error`, `log_debug`.
- **Fatal errors**: use `die "message"`.
- **Subshells**: `(cd "$dir" && command)` for scoped directory changes.

### Things to Avoid

| Don't | Do Instead | Why |
|-------|-----------|-----|
| `eval "$user_input"` | Use arrays: `"${cmd[@]}"` | Command injection risk |
| `echo -e "text"` | `printf 'text\n'` | Not portable across systems |
| `((var++))` | `var=$((var + 1))` | Exits with set -e when var=0 |
| `set -euo pipefail` in lib files | Only in `bin/claudemix` | Sourced files inherit from entry point |
| `rm -rf "$path"` without validation | Check path is inside expected dir | Accidental deletion risk |
| Bash arrays in `#!/bin/sh` scripts | POSIX `IFS` + `for` loops | Generated hooks must be portable |
| `&>/dev/null` | `>/dev/null 2>&1` | More portable across shells |

### File Organization

- **`bin/claudemix`**: Entry point only. Argument parsing, routing, help text. No business logic.
- **`lib/core.sh`**: Shared utilities used by all other modules. Source of truth for config, logging, constants.
- **`lib/*.sh`**: Feature modules. Each handles one concern. Sourced by entry point, never executed directly.
- **`install.sh`**: Self-contained installer. Must work standalone (no sourcing lib files).

### Adding a New Feature

1. Determine which module it belongs to (or create a new `lib/feature.sh`)
2. Implement the function in the appropriate module
3. Add routing in `bin/claudemix` `main()` function
4. Add to `_show_help()` in `bin/claudemix`
5. Add TUI menu option in `lib/tui.sh` (both gum and fallback paths)
6. Add shell completions in `completions/claudemix.{zsh,bash}`
7. Document in `README.md`
8. Update `CLAUDE.md` if it affects agent behavior

## Testing

Currently we use manual testing. We're looking for help setting up [bats-core](https://github.com/bats-core/bats-core) for automated tests.

### Manual Test Checklist

Before submitting a PR, verify:

- [ ] `bash -n` passes on all changed files
- [ ] `claudemix version` works
- [ ] `claudemix help` shows updated help text (if commands changed)
- [ ] Feature works from a real git project directory
- [ ] Feature works without tmux installed
- [ ] Feature works without gum installed
- [ ] No shellcheck warnings (if you have shellcheck installed)

### Running shellcheck

```bash
# Install: brew install shellcheck (macOS) | apt install shellcheck (Linux)
shellcheck bin/claudemix lib/*.sh install.sh
```

## Pull Request Guidelines

- **One feature per PR** — keep PRs focused and reviewable
- **Descriptive title** — use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`
- **Update docs** — if you add/change commands, update README.md and help text
- **Test on both macOS and Linux** if possible (or note which platform you tested on)

## Project Structure

```
ClaudeMix/
├── bin/
│   └── claudemix              # Entry point (only file with set -euo pipefail)
├── lib/
│   ├── core.sh                # Foundation (config, logging, utils)
│   ├── session.sh             # Session lifecycle
│   ├── worktree.sh            # Git worktree management
│   ├── merge-queue.sh         # Branch consolidation
│   ├── hooks.sh               # Git hooks installer
│   └── tui.sh                 # Interactive menus
├── completions/
│   ├── claudemix.zsh          # Zsh completions
│   └── claudemix.bash         # Bash completions
├── install.sh                 # Installer
├── .claudemix.yml.example     # Example config
├── CLAUDE.md                  # Claude Code agent instructions
├── AGENTS.md                  # Multi-agent patterns guide
├── CONTRIBUTING.md            # This file
├── LICENSE                    # MIT
└── README.md                  # Documentation
```

## Areas Where Help Is Needed

- **Automated tests** — set up bats-core test suite
- **Linux testing** — verify all features work on common Linux distros
- **Fish shell completions** — `completions/claudemix.fish`
- **Homebrew formula** — package for `brew install claudemix`
- **GitLab/Bitbucket support** — merge queue currently only supports GitHub (gh CLI)
- **Session templates** — pre-configured session types with Claude prompts
- **Conflict detection** — warn when two sessions are editing the same files

## Code of Conduct

Be respectful, constructive, and collaborative. We're all here to make Claude Code better.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
