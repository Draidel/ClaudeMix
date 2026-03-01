# TUI UX Improvement Design

Date: 2026-03-01

## Problem

The current dashboard uses cryptic symbols (`o`, `*`, `+15!`, `~`, `ok`) that require memorizing a legend. Session info is hard to parse at a glance.

## Design

### Session display — two-line format

Each session rendered as two lines:

```
  1  ● auth-fix                              stopped · 19h
     auth-fix  15 ahead · dirty
```

Line 1: index, status dot, session name, right-aligned state + age.
Line 2: indented short branch name, human-readable change summary.

- Green `●` = running, red `●` = stopped
- "15 ahead" replaces `+15!`
- "dirty" replaces `~`
- "clean" replaces `ok`
- Validation: `✓` / `✗` appended to line 2 when present
- Branch shown as short name (strip `claudemix/` prefix)

### Health bar — always visible, improved format

Keep dependency status visible every time. Same `+cmd` / `-cmd` format with disk usage.

### Action bar — bracketed hotkeys

`[n] new` instead of `n new` for clearer visual parsing.

### Merge section — Unicode arrow

`MERGE → main (squash)` instead of `MERGE -> main (squash)`.

### Scope

Only `lib/tui.sh` — specifically `_tui_render_dashboard()` and session line builder in `_tui_gather_data()`. No changes to data collection logic, menu flows, or session management.

### Example

```
  ClaudeMix v0.2.0                           main +2

  SESSIONS (2)
  1  ● auth-fix                              stopped · 19h
     auth-fix  15 ahead · dirty

  2  ● ui-update                             running · 19h
     ui-update  clean

  MERGE → main (squash)  0 ready

  +git +claude -tmux +gum +gh  664K

  [n] new  [1-2] attach  [m] merge  [k] kill  [v] validate
  [c] cleanup  [h] hooks  [i] config  [q] quit
```
