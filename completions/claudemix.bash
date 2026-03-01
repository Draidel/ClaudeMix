# ClaudeMix Bash completion

_claudemix() {
  local cur prev commands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  commands="ls list open close kill merge cleanup clean dashboard dash hooks config init version help"

  case "$prev" in
    claudemix)
      # Complete commands + session names
      local sessions
      sessions="$(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null)"
      COMPREPLY=($(compgen -W "$commands $sessions" -- "$cur"))
      ;;
    kill)
      local sessions
      sessions="$(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null) all"
      COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
      ;;
    hooks)
      COMPREPLY=($(compgen -W "install uninstall status" -- "$cur"))
      ;;
    merge)
      COMPREPLY=($(compgen -W "list ls" -- "$cur"))
      ;;
    open|close)
      local sessions
      sessions="$(claudemix ls 2>/dev/null | tail -n +3 | awk '{print $1}' 2>/dev/null)"
      COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
      ;;
    config)
      COMPREPLY=($(compgen -W "show edit init" -- "$cur"))
      ;;
  esac
}

complete -F _claudemix claudemix
