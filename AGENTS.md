# AGENTS.md — ClaudeMix Multi-Agent Patterns

Guide for using ClaudeMix to orchestrate multiple Claude Code agents working on the same project simultaneously.

## Overview

ClaudeMix enables parallel AI-assisted development by giving each Claude Code session its own isolated environment. This document covers patterns and best practices for multi-agent workflows.

## Core Concepts

### Session Isolation Model

Each `claudemix <name>` session gets:

| Layer | Isolation | Mechanism |
|-------|-----------|-----------|
| **Files** | Full | Git worktree (separate working directory) |
| **Branch** | Full | Dedicated branch (`claudemix/<name>`) |
| **Terminal** | Full | Separate tmux session or foreground process |
| **Dependencies** | Shared store | Package manager shared cache (pnpm store, yarn cache) |
| **Git history** | Shared | Same `.git` directory (read: shared, write: branch-isolated) |

### When to Use Multiple Sessions

**Good candidates for parallel sessions:**
- Independent features (auth system + UI redesign + API refactor)
- Bug fixes across different modules
- Test writing alongside feature development
- Documentation + code changes simultaneously
- Performance optimization experiments

**Bad candidates (use single session instead):**
- Tightly coupled changes to the same files
- Sequential dependencies (B requires A to be done first)
- Database migration + code that depends on it

## Workflow Patterns

### Pattern 1: Feature Parallelism

Run multiple independent features simultaneously:

```bash
claudemix auth-rewrite         # Session 1: Authentication overhaul
claudemix dashboard-redesign   # Session 2: Dashboard UI
claudemix api-v2               # Session 3: API versioning
claudemix test-coverage        # Session 4: Test backfill
```

Each session works independently. When done:

```bash
claudemix merge                # Consolidate into one PR
```

### Pattern 2: Explore + Implement

Use one session for research, another for implementation:

```bash
claudemix explore-auth         # Session 1: Research auth patterns, read docs
claudemix impl-auth            # Session 2: Implement based on findings
```

### Pattern 3: Fix + Validate

One session fixes, another validates:

```bash
claudemix fix-types            # Session 1: Fix TypeScript errors
claudemix validate-build       # Session 2: Run builds, catch regressions
```

### Pattern 4: Specialist Sessions

Assign sessions to specialized tasks:

```bash
claudemix security-audit       # Focused on security review
claudemix perf-optimize        # Focused on performance
claudemix accessibility        # Focused on a11y compliance
```

## CLAUDE.md Worktree Policy

Add this to your project's `CLAUDE.md` to guide Claude Code agents in worktree sessions:

```markdown
## Worktree Session Guidelines

When running in a ClaudeMix worktree session:

1. **Stay on your branch** — never checkout other branches
2. **Commit frequently** — small, focused commits help merge queue
3. **Push when ready** — pre-push hooks validate automatically
4. **Don't modify shared config** — avoid changing root configs that affect other sessions
5. **Use your session's scope** — focus on the task your session was created for
```

## Merge Strategies

### Squash Merge (Recommended)

```yaml
# .claudemix.yml
merge_strategy: squash
```

Best for most teams. Each consolidated PR becomes one clean commit. Individual session commits are preserved in the PR description.

### Regular Merge

```yaml
merge_strategy: merge
```

Preserves full commit history from all sessions. Good when individual commit messages matter for audit trails.

### Rebase

```yaml
merge_strategy: rebase
```

Linear history. Good for projects that require a clean, linear git log.

## Conflict Handling

### Prevention

1. **Scope sessions narrowly** — one feature per session, avoid overlapping files
2. **Use different directories** — if possible, assign sessions to different parts of the codebase
3. **Merge frequently** — don't let sessions diverge too far from the base branch

### When Conflicts Happen

The merge queue handles conflicts gracefully:

1. `claudemix merge` attempts to merge each selected branch
2. If a branch conflicts, it's skipped (not merged)
3. The PR lists which branches were merged and which were skipped
4. Skipped branches can be rebased manually and merged in a follow-up

```bash
# If branch conflicts during merge queue:
git checkout claudemix/conflicting-branch
git rebase staging
# Resolve conflicts
git push --force-with-lease
# Then run merge queue again for this branch
```

## Resource Considerations

### Memory

Each Claude Code session uses significant memory. Monitor resource usage:

```bash
# Check memory usage of Claude processes
ps aux | grep claude | grep -v grep

# Recommended: limit concurrent sessions based on available RAM
# 16GB RAM → 3-4 sessions
# 32GB RAM → 6-8 sessions
# 64GB RAM → 10-12 sessions
```

### Package Installation

ClaudeMix leverages shared package stores for fast dependency installation:

- **pnpm**: Content-addressable store (shared by default)
- **yarn**: Global cache
- **npm**: Global cache (use `npm ci` for deterministic installs)

First session takes longest for dependency install. Subsequent sessions are near-instant.

## Integration with SuperClaude

If you use [SuperClaude Framework](https://github.com/SuperClaude-Org/SuperClaude_Framework), ClaudeMix works alongside it:

```
Developer
  ├── ClaudeMix (session orchestration)
  │     └── spawns Claude Code instances
  │           └── each with SuperClaude loaded (personas, skills, modes)
  └── Git + CI (version control + deployment)
```

ClaudeMix manages the "where" and "when" of sessions. SuperClaude manages the "how" of AI behavior within each session.

## Troubleshooting Multi-Agent Issues

### Orphaned tmux sessions

```bash
claudemix ls                    # Shows orphaned sessions
claudemix kill <name>           # Clean up specific session
claudemix kill all              # Nuclear option
```

### Stale worktrees

```bash
claudemix cleanup               # Remove worktrees for merged branches
git worktree prune              # Clean up git's worktree registry
```

### Branch divergence

If a session branch falls too far behind:

```bash
cd .claudemix/worktrees/<name>
git fetch origin
git rebase origin/staging       # Or your base branch
```
