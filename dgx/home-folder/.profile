# ~/.profile
# Login environment (POSIX sh). Keep this non-interactive.

# Only set env vars here that should exist for every shell.
export EDITOR=nvim
export LANG=en_US.UTF-8

# If you want a PATH extension that applies everywhere:
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# If zsh is your default shell, you generally don't need to exec it here.
# Avoid interactive commands (neofetch, prompt setup, aliases, etc.).
