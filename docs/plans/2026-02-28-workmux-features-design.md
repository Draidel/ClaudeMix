# ClaudeMix — Workmux-Inspired Feature Integration Design

**Date**: 2026-02-28
**Approach**: Big Bang — all 8 features in a single branch
**Inspired by**: [workmux](https://github.com/raine/workmux)

## Features

1. Config system expansion (global + project + lifecycle hooks + file ops + pane config)
2. Worktree lifecycle hooks (post_create, pre_merge, pre_remove)
3. File copy/symlink on worktree creation
4. Pane layouts (arbitrary commands alongside Claude in tmux splits)
5. Session open/close separation (decouple tmux window from worktree lifecycle)
6. `--with-changes` flag (move uncommitted work into new session)
7. `--pr` flag (create session from GitHub PR)
8. Enhanced `ls` + live dashboard

---

## 1. Config System Expansion

### Global config

Location: `~/.config/claudemix/config.yaml` (respects `$XDG_CONFIG_HOME`).
Same flat YAML parser. Loaded first, then project config overrides.

**Global-only keys**:

| Key | Default | Purpose |
|-----|---------|---------|
| `editor` | `$EDITOR` or `vim` | Editor for `claudemix config edit` |
| `dashboard_refresh` | `2` | Dashboard refresh interval (seconds) |

### New project config keys

| Key | Default | Purpose |
|-----|---------|---------|
| `post_create` | `""` | Command to run after worktree creation |
| `pre_merge` | `""` | Command to run before merge |
| `pre_remove` | `""` | Command to run before worktree removal |
| `copy_files` | `""` | Comma-separated globs to copy into worktrees |
| `symlink_files` | `""` | Comma-separated globs to symlink into worktrees |
| `panes` | `""` | Pane layout definition |

### Loading order

1. `_load_global_config()` — sets CFG_* from global file
2. `load_config()` — project file overrides CFG_* values
3. `_detect_defaults()` — fills remaining gaps
4. `_validate_config()` — validates everything

### Script hooks directory

If `.claudemix/hooks/post_create` (or pre_merge, pre_remove) exists and is executable, it runs **instead of** the YAML inline command. Environment variables:

- `CLAUDEMIX_NAME` — session name
- `CLAUDEMIX_WORKTREE_PATH` — absolute path to worktree
- `CLAUDEMIX_PROJECT_ROOT` — absolute path to project root
- `CLAUDEMIX_BRANCH` — branch name
- `CLAUDEMIX_BASE_BRANCH` — base branch name

---

## 2. Worktree Lifecycle Hooks

### Hook execution model

New function `_run_lifecycle_hook` in `worktree.sh`:

**Resolution order**:
1. Check `.claudemix/hooks/$hook_name` — if executable, run it
2. Else check corresponding `CFG_*` value from config
3. If neither exists, skip silently

**Execution**: `bash -c "$command"` in subshell with env vars. Non-zero exit = log warning but don't block (except `pre_merge` — that blocks the merge).

### Execution order in `worktree_create`

1. `git worktree add` (existing)
2. `_worktree_copy_files` (NEW)
3. `_worktree_install_deps` (existing)
4. `_run_lifecycle_hook "post_create"` (NEW)

### Execution order in `worktree_remove`

1. `_run_lifecycle_hook "pre_remove"` (NEW)
2. `git worktree remove` (existing)
3. Branch deletion (existing)

---

## 3. File Copy/Symlink on Worktree Create

New function `_worktree_copy_files` called from `worktree_create`.

1. Parse `CFG_COPY_FILES` (comma-separated): for each glob, find matching files in `$PROJECT_ROOT`, copy to same relative path in worktree. Skip if already exists.
2. Parse `CFG_SYMLINK_FILES` (comma-separated): for each glob, find matching paths in `$PROJECT_ROOT`, create symlink pointing back to the original.

**Safety**:
- Only match files inside `$PROJECT_ROOT`
- Symlinks point to absolute paths
- Never overwrite existing files in the worktree
- Log each copy/symlink

---

## 4. Pane Layouts

### Config format

```yaml
# Claude only (default, backward compatible)
panes: claude

# Two panes: dev server left, Claude right
panes: "npm run dev | claude"

# Three panes: dev server top-left, tests bottom-left, Claude right
panes: "npm run dev / pnpm test | claude"
```

**Syntax**:
- `|` = vertical split (side by side)
- `/` = horizontal split (stacked)
- `claude` = magic keyword replaced with actual Claude command
- Empty/unset = defaults to `claude` (backward compatible)

### Implementation

In `_session_launch_tmux`:
1. Parse panes string into layout
2. Create tmux session with first pane's command
3. `tmux split-window` with `-h` (vertical) or `-v` (horizontal) for each additional pane
4. Select the Claude pane as active
5. Apply `tmux select-layout tiled` or calculated layout

### Parser

`_parse_panes` outputs structured data:
```
# direction\tcommand
h	npm run dev
h	pnpm test
v	claude
```

`|` splits first (columns), then `/` splits within each column (rows).

### Per-session override

`claudemix myname --panes "npm run dev | claude"` — stored in session metadata.

### No-tmux fallback

Warn and only run the Claude pane.

---

## 5. Session Open/Close Separation

### New commands

| Command | Effect |
|---------|--------|
| `claudemix close <name>` | Kill tmux session, keep worktree + branch + metadata |
| `claudemix open <name>` | Reopen tmux session for existing worktree |
| `claudemix kill <name>` | Kill tmux + remove worktree (unchanged) |

### New functions in `session.sh`

**`session_close`**:
- Kill tmux session (exact match)
- Update metadata: `status=closed`
- Keep worktree, branch, metadata

**`session_open`**:
- Verify worktree exists
- If tmux running, just attach
- Otherwise rebuild tmux with pane layout, attach
- Update metadata: `status=open`

### Enhanced `session_list`

Third status: `closed` (worktree exists, no tmux). Distinct from `stopped` (tmux died unexpectedly).

---

## 6. `--with-changes` Flag

`claudemix <name> --with-changes` — move uncommitted work to new session.

### Flow

1. Detect `--with-changes` in args
2. If current tree clean, warn and continue normally
3. If dirty:
   a. `git stash push -u -m "claudemix: moving to $name"`
   b. Create worktree normally
   c. `git stash pop` inside new worktree
   d. If conflicts, warn user

### Arg parsing in `session_create`

```bash
local with_changes=false
local pr_number=""
local panes_override=""
local -a extra_flags=()
for arg in "$@"; do
  case "$arg" in
    --with-changes)  with_changes=true ;;
    --pr=*)          pr_number="${arg#--pr=}" ;;
    --panes=*)       panes_override="${arg#--panes=}" ;;
    *)               extra_flags+=("$arg") ;;
  esac
done
```

---

## 7. `--pr` Flag

`claudemix <name> --pr 42` — create session from GitHub PR.

### Flow

1. Require `gh` CLI
2. `gh pr checkout $pr_number --branch "claudemix/$name"`
3. Create worktree from that branch (branch already exists)
4. Normal flow: file copy, dep install, hooks, tmux launch

---

## 8. Enhanced `ls` + Dashboard

### Enhanced `session_list`

New column: **PANES** — `running/total` from tmux.

```
NAME           BRANCH                    STATUS    PANES    GIT              CREATED
auth-fix       claudemix/auth-fix        running   3/3      2 ahead, dirty   Feb 28 14:30
ui-update      claudemix/ui-update       closed    0/2      5 ahead          Feb 28 13:15
```

### Dashboard: `claudemix dashboard`

`watch`-style refresh loop:
- Clear screen, print timestamp
- Show session table
- Show per-session pane status (command + running/exited)
- `q` to quit, auto-refresh every `$CFG_DASHBOARD_REFRESH` seconds

### New file: `lib/dashboard.sh`

Contains `dashboard_run` and `_dashboard_show_panes`. Depends on core.sh, session.sh.

---

## File Change Summary

| File | Changes |
|------|---------|
| `lib/core.sh` | New CFG_* globals, `_load_global_config()`, expanded `load_config()`, new validation, updated `write_default_config()` |
| `lib/worktree.sh` | `_run_lifecycle_hook()`, `_worktree_copy_files()`, `_worktree_symlink_files()`, hook calls in create/remove |
| `lib/session.sh` | `session_open()`, `session_close()`, `--with-changes`, `--pr`, `--panes` override, pane layout in `_session_launch_tmux()`, `_parse_panes()`, enhanced `session_list`, arg parsing |
| `lib/dashboard.sh` | **New** — `dashboard_run()`, `_dashboard_show_panes()` |
| `lib/merge-queue.sh` | `pre_merge` hook call |
| `lib/tui.sh` | New menu items (Open, Close, Dashboard, Global config) |
| `bin/claudemix` | New command routing, source dashboard.sh, updated help |
| `.claudemix.yml.example` | New config keys |
| `completions/claudemix.zsh` | New commands |
| `completions/claudemix.bash` | New commands |
