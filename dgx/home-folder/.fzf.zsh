# Setup fzf
# ---------
if [[ ! "$PATH" == */home/aaron/.fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/home/aaron/.fzf/bin"
fi

source <(fzf --zsh)
