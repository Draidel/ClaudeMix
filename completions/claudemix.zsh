#compdef claudemix

# ClaudeMix Zsh completion

_claudemix() {
  local -a commands
  commands=(
    'ls:List active sessions'
    'list:List active sessions'
    'kill:Kill a session'
    'merge:Consolidate branches into a single PR'
    'cleanup:Remove worktrees for merged branches'
    'clean:Remove worktrees for merged branches'
    'hooks:Manage git hooks'
    'init:Generate .claudemix.yml config'
    'version:Show version'
    'help:Show help'
  )

  local -a hooks_subcommands
  hooks_subcommands=(
    'install:Install pre-commit and pre-push hooks'
    'uninstall:Remove ClaudeMix hooks'
    'status:Show current hook status'
  )

  local -a merge_subcommands
  merge_subcommands=(
    'list:Show branches eligible for merge'
    'ls:Show branches eligible for merge'
  )

  _arguments -C \
    '1:command:->command' \
    '*::args:->args'

  case "$state" in
    command)
      # Complete commands + active session names
      _describe 'command' commands
      # Also complete session names for quick attach
      local sessions
      sessions=($(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null))
      if (( ${#sessions[@]} > 0 )); then
        _describe 'session' sessions
      fi
      ;;
    args)
      case "${words[1]}" in
        kill)
          local sessions
          sessions=($(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null))
          sessions+=('all:Kill all sessions')
          _describe 'session' sessions
          ;;
        hooks)
          _describe 'hooks subcommand' hooks_subcommands
          ;;
        merge)
          _describe 'merge subcommand' merge_subcommands
          ;;
      esac
      ;;
  esac
}

_claudemix "$@"
