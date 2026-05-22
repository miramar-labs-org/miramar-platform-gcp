# --- Conda/Miniforge init for zsh ---
if [[ -x /opt/miniforge3/bin/conda ]]; then
  __conda_setup="$('/opt/miniforge3/bin/conda' 'shell.zsh' 'hook' 2>/dev/null)"
  if [[ $? -eq 0 && -n "${__conda_setup}" ]]; then
    eval "${__conda_setup}"
  else
    [[ -f /opt/miniforge3/etc/profile.d/conda.sh ]] && source /opt/miniforge3/etc/profile.d/conda.sh
  fi
  unset __conda_setup
fi

# Secrets
[[ -f ~/.config/zsh/secrets.zsh ]] && source ~/.config/zsh/secrets.zsh

# Load pyenv once
if [[ -z "${__PROFILED_LOADED:-}" ]]; then
  export __PROFILED_LOADED=1
  [[ -f /etc/profile.d/pyenv.sh ]] && source /etc/profile.d/pyenv.sh
fi

# Extra completions before Oh My Zsh
fpath=(~/.zsh/zsh-completions/src $fpath)

# --- Oh My Zsh ---
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
  git
  fzf
  conda
  poetry
  python
  docker
  kubectl
  tmux
)

ZSH_DISABLE_COMPFIX=true
source "$ZSH/oh-my-zsh.sh"

# fzf
[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh

# Autosuggestions
[[ -f ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh

# Syntax highlighting
[[ -f ~/.zsh/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh ]] && source ~/.zsh/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh

# fzf-tab after OMZ/compinit
[[ -f ~/.zsh/fzf-tab/fzf-tab.plugin.zsh ]] && source ~/.zsh/fzf-tab/fzf-tab.plugin.zsh

# Powerlevel10k
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# Custom env
export LANGCHAIN_TRACING_V2="true"
[[ -n "${NGC_API_KEY:-}" ]] && export NVIDIA_API_KEY="$NGC_API_KEY"
alias jlab='jupyter lab --ip=0.0.0.0 --port=8080 --allow-root'
alias tmx='tmux new -A -s main'

[[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env"

# need this for nemoclaw
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# fastfetch on top-level interactive shells, including top-level SSH
# Do not show inside tmux
# Do not show for non-interactive shells
if command -v fastfetch >/dev/null 2>&1; then
  if [[ $- == *i* && -z "$TMUX" && -z "${__FASTFETCH_SHOWN:-}" ]]; then
    export __FASTFETCH_SHOWN=1
    fastfetch
  fi
fi
