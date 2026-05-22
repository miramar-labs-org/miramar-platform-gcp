# ~/.zshenv
# Loaded for *all* zsh shells. Keep it FAST and QUIET.

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export EDITOR="nvim"

# Canonical PATH (dedupe and predictable ordering)
typeset -U path PATH

# Put preferred bins first
path=(
  "$HOME/.local/bin"
  "$HOME/.fzf/bin"
  $path
)

export PATH
