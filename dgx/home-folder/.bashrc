# ~/.bashrc
# Bash interactive shell config

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Optional: make bash behave nicely when you do use it
export HISTCONTROL=ignoredups:erasedups
shopt -s histappend

# If you want neofetch in bash too, do it here with a run-once guard:
if [[ -z "${NEOFETCH_SHOWN:-}" ]]; then
  export NEOFETCH_SHOWN=1
  command -v neofetch >/dev/null 2>&1 && neofetch
fi
