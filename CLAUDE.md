# CLAUDE.md — ClaudeMix

Instructions for Claude Code agents working on the ClaudeMix codebase.

## Project Overview

**ClaudeMix** is a multi-session orchestrator for Claude Code — a shell-native CLI tool that manages concurrent Claude sessions using git worktrees, tmux, and a merge queue. Written entirely in bash.

**Repository**: https://github.com/Draidel/ClaudeMix
**License**: MIT

## Architecture

```
bin/claudemix       Entry point (set -euo pipefail, argument parsing, routing)
lib/core.sh         Foundation: constants, colors, logging, YAML config, pkg detection, utils
lib/session.sh      Session CRUD: create, attach, list, kill (tmux + worktree lifecycle)
lib/worktree.sh     Git worktree management: create, remove, list, cleanup merged
lib/hooks.sh        Git hooks installer: husky path (Node.js) + direct path (others)
lib/merge-queue.sh  Branch consolidation: select, merge, validate, push, create PR
lib/dashboard.sh    Live dashboard: session monitoring, pane status display
lib/tui.sh          Interactive TUI menus (gum with basic prompt fallback)
install.sh          Installer: clone, PATH, completions, dependency check
```

### Key Design Constraints

1. **No eval on user input** — use bash arrays for command building, `printf '%q'` for tmux escaping
2. **Library files are sourced** — they MUST NOT contain `set -euo pipefail` (only the entry point sets this)
3. **Generated hooks must be POSIX** — use `#!/bin/sh`, no bash arrays, no `[[ ]]`, no `read -ra`
4. **Counter increments** — use `var=$((var + 1))` instead of `((var++))` (the latter exits with set -e when var=0)
5. **Path validation** — always validate paths before `rm -rf`, ensure they're inside expected directories
6. **Cross-platform** — handle BSD date (macOS) vs GNU date (Linux), provide both brew and apt hints
7. **Config values are user-controlled** — sanitize before embedding in generated scripts

## Code Style

- **Naming**: `snake_case` for functions and variables, `UPPER_CASE` for constants/globals
- **Private functions**: prefix with `_` (e.g., `_session_launch_tmux`)
- **Output**: use `printf` instead of `echo` for portability (no `echo -e`)
- **Logging**: use `log_info`, `log_ok`, `log_warn`, `log_error`, `log_debug` from core.sh
- **Error handling**: use `die "message"` for fatal errors
- **Heredocs**: use `'DELIMITER'` (single-quoted) for literal content, unquoted for variable interpolation
- **Subshells**: use `(cd "$dir" && command)` for directory-scoped commands
- **Config access**: all config values are `CFG_*` globals set by `load_config`

## Testing

```bash
# Syntax check all scripts
for f in bin/claudemix lib/*.sh install.sh; do bash -n "$f" && echo "$f OK"; done

# Quick functional test
bash bin/claudemix version
bash bin/claudemix help

# Test from a git project directory
cd /path/to/any-git-project
/path/to/ClaudeMix/bin/claudemix ls
/path/to/ClaudeMix/bin/claudemix hooks status
```

There are no automated tests yet. When adding tests, use [bats-core](https://github.com/bats-core/bats-core).

## Common Patterns

### Adding a new config key

1. Add `declare -g CFG_NEW_KEY=""` in `core.sh` (config defaults section)
2. Add case in `load_config()` case statement
3. Add auto-detection in `_detect_defaults()` if applicable
4. Add to `write_default_config()`
5. Add to `.claudemix.yml.example`
6. If applicable, add to `write_global_config()` in `core.sh`
7. Document in README.md

### Adding a new command

1. Add case in `main()` in `bin/claudemix`
2. Implement function in appropriate `lib/*.sh` module
3. Add to `_show_help()` in `bin/claudemix`
4. Add to `_tui_choose_action()` in `tui.sh` (both gum and fallback paths)
5. Add to `completions/claudemix.{zsh,bash,fish}`

### DRY helpers

- **Package manager**: use `detect_pkg_manager "$dir"` (core.sh) — never duplicate detection
- **Config writing**: use `write_default_config "$path"` (core.sh) — never duplicate config template
- **Sanitize names**: use `sanitize_name "$input"` (core.sh) — dies on invalid input

## Dependencies

**External commands used** (must handle absence gracefully):
- `git` — required (worktree, branch, merge, fetch, push)
- `claude` — required (Claude Code CLI)
- `tmux` — optional (session persistence)
- `gum` — optional (interactive TUI)
- `gh` — optional (PR creation)
- `node` — optional (husky/lint-staged JSON manipulation)
- `sed`, `tr`, `cut`, `grep`, `printf`, `date`, `basename`, `dirname`, `readlink` — POSIX utils

## File Relationships

```
bin/claudemix
  └─ sources ─→ lib/core.sh (always first)
                 lib/worktree.sh (depends on core.sh)
                 lib/session.sh (depends on core.sh, worktree.sh)
                 lib/hooks.sh (depends on core.sh)
                 lib/merge-queue.sh (depends on core.sh, worktree.sh)
                 lib/dashboard.sh (depends on core.sh, session.sh)
                 lib/tui.sh (depends on core.sh, session.sh, worktree.sh, hooks.sh, merge-queue.sh)
```

## Security Notes

- `CFG_CLAUDE_FLAGS` is split into an array via `read -ra` — safe for flag passing
- `CFG_VALIDATE` is executed via `bash -c "$CFG_VALIDATE"` — runs in subshell, not via eval
- Protected branches in hooks are sanitized to `[a-zA-Z0-9,_./-]` before embedding
- `sanitize_name()` strips everything except `[a-zA-Z0-9_-]` and dies on empty result
- `worktree_remove()` validates the path is inside `$CFG_WORKTREE_DIR` before rm -rf
- tmux commands use `printf '%q'` for shell escaping, not string interpolation
- Node scripts use `<< 'HEREDOC'` (single-quoted) to prevent shell expansion
