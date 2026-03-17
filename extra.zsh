# Restart the Nix daemon after MacOS upgrades.
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi

# Required to load nvm.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Required for zsh.
eval "$(direnv hook zsh)"

# Required for GitHub flows.
export GITHUB_TOKEN=$(security find-generic-password -a "$USER" -s "metropolis-github-token" -w 2>/dev/null)

# Required for claude code.
export PATH="$HOME/.local/bin:$PATH"

# Required for bun.
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Set up zoxide.
# Overriding `cd` doesn't play well with Claude Code, so we avoid that for now.
eval "$(zoxide init zsh)"
