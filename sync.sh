#!/usr/bin/env bash

set -eo pipefail

rm -rf ~/.config/nvim 2>/dev/null
rm -rf ~/.config/wezterm 2>/dev/null
rm -rf ~/.config/starship.toml 2>/dev/null
rm -rf ~/.config/aerospace 2>/dev/null

mkdir -p ~/.config/wezterm
mkdir -p ~/.config/aerospace

ln -s ~/.config/home-manager/nvim ~/.config/nvim
ln -s ~/.config/home-manager/wezterm.lua ~/.config/wezterm/wezterm.lua 2>/dev/null
ln -s ~/.config/home-manager/aerospace.toml ~/.config/aerospace/aerospace.toml 2>/dev/null
ln -s ~/.config/home-manager/starship.toml ~/.config/starship.toml 2>/dev/null

# Detect what machine we're on to apply the correct home-manager config.
if [[ "$(hostname)" == "Austins-MacBook-Air.local" ]]; then
  FLAKE_TARGET="personal"
else
  FLAKE_TARGET="work"
fi

if ! command -v home-manager &>/dev/null; then
  nix run home-manager -- switch --flake .#${FLAKE_TARGET}
else
  home-manager switch --flake .#${FLAKE_TARGET}
fi
