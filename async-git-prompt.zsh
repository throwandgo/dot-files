# Async git status for the starship prompt.
#
# starship computes git_status synchronously before drawing the prompt. In ~/site the untracked-file
# scan alone takes ~400ms (EDR intercepts every readdir; fsmonitor and untrackedCache don't help),
# so every Enter lagged. Instead, the prompt draws at once with the last known status for this
# directory, and a background `starship module git_status` repaints it when it finishes. starship
# shows the result via the env_var.git_status_async module (see starship.toml).
#
# Sourced after starship/mise/direnv init so this precmd hook runs last and never clobbers the $?
# and $pipestatus that starship's own precmd reads.

typeset -gi _agp_fd=0
typeset -g _agp_pwd=""

_agp_stop() {
  if (( _agp_fd )); then
    zle -F ${_agp_fd} 2>/dev/null
    exec {_agp_fd}<&-
    _agp_fd=0
  fi
}

_agp_done() {
  emulate -L zsh
  setopt extended_glob
  local fd=$1 out=""
  IFS= read -r -d '' -u ${fd} out
  _agp_stop
  # Strip zsh prompt escapes and ANSI colours; starship re-styles the plain text.
  out=${out//\%\{[^\}]#\%\}/}
  out=${out//$'\e'\[[0-9;]#m/}
  out=${out//\%\%/%}
  if [[ -z ${out//[[:space:]]/} ]]; then
    unset STARSHIP_GIT_STATUS
  else
    export STARSHIP_GIT_STATUS=${out}
  fi
  zle reset-prompt
}
zle -N _agp_done

_agp_precmd() {
  # Show the previous status until the new one lands, but never another directory's.
  if [[ ${PWD} != "${_agp_pwd}" ]]; then
    unset STARSHIP_GIT_STATUS
    _agp_pwd=${PWD}
  fi
  _agp_stop
  exec {_agp_fd}< <(starship module git_status 2>/dev/null)
  zle -F -w ${_agp_fd} _agp_done
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _agp_precmd
