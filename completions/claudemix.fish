# ClaudeMix Fish completion

# Disable file completions by default
complete -c claudemix -f

# Helper: list active session names
function __claudemix_sessions
    claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null
end

# Top-level commands
complete -c claudemix -n "__fish_use_subcommand" -a "ls" -d "List active sessions"
complete -c claudemix -n "__fish_use_subcommand" -a "list" -d "List active sessions"
complete -c claudemix -n "__fish_use_subcommand" -a "kill" -d "Kill a session"
complete -c claudemix -n "__fish_use_subcommand" -a "merge" -d "Consolidate branches into a single PR"
complete -c claudemix -n "__fish_use_subcommand" -a "cleanup" -d "Remove worktrees for merged branches"
complete -c claudemix -n "__fish_use_subcommand" -a "clean" -d "Remove worktrees for merged branches"
complete -c claudemix -n "__fish_use_subcommand" -a "hooks" -d "Manage git hooks"
complete -c claudemix -n "__fish_use_subcommand" -a "init" -d "Generate .claudemix.yml config"
complete -c claudemix -n "__fish_use_subcommand" -a "version" -d "Show version"
complete -c claudemix -n "__fish_use_subcommand" -a "help" -d "Show help"
complete -c claudemix -n "__fish_use_subcommand" -a "open" -d "Reopen a closed session"
complete -c claudemix -n "__fish_use_subcommand" -a "close" -d "Close session (keep worktree)"
complete -c claudemix -n "__fish_use_subcommand" -a "dashboard" -d "Live session monitoring"
complete -c claudemix -n "__fish_use_subcommand" -a "dash" -d "Live session monitoring"
complete -c claudemix -n "__fish_use_subcommand" -a "config" -d "Manage configuration"

# Dynamic session names at top level (for quick attach)
complete -c claudemix -n "__fish_use_subcommand" -a "(__claudemix_sessions)" -d "Attach to session"

# kill subcommands: session names + "all"
complete -c claudemix -n "__fish_seen_subcommand_from kill" -a "(__claudemix_sessions)" -d "Session"
complete -c claudemix -n "__fish_seen_subcommand_from kill" -a "all" -d "Kill all sessions"

# hooks subcommands
complete -c claudemix -n "__fish_seen_subcommand_from hooks" -a "install" -d "Install pre-commit and pre-push hooks"
complete -c claudemix -n "__fish_seen_subcommand_from hooks" -a "uninstall" -d "Remove ClaudeMix hooks"
complete -c claudemix -n "__fish_seen_subcommand_from hooks" -a "status" -d "Show current hook status"

# merge subcommands
complete -c claudemix -n "__fish_seen_subcommand_from merge" -a "list" -d "Show branches eligible for merge"
complete -c claudemix -n "__fish_seen_subcommand_from merge" -a "ls" -d "Show branches eligible for merge"

# open/close subcommands: session names
complete -c claudemix -n "__fish_seen_subcommand_from open" -a "(__claudemix_sessions)" -d "Session"
complete -c claudemix -n "__fish_seen_subcommand_from close" -a "(__claudemix_sessions)" -d "Session"

# config subcommands
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "show" -d "Show merged configuration"
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "edit" -d "Edit global config"
complete -c claudemix -n "__fish_seen_subcommand_from config" -a "init" -d "Create global config"
