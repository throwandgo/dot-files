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

if ! command -v home-manager &>/dev/null; then
  nix run home-manager -- init --switch
else
  home-manager switch
fi

if [[ "$(uname)" == "Darwin" ]]; then
  HOME_APPS="$HOME"/Applications
  NIX_APPS="$HOME"/.nix-profile/Applications

  # remove broken links
  for f in "$HOME_APPS"/*; do
    if [ -L "$f" ] && [ ! -e "$f" ]; then
      rm "$f"
    fi
  done

  # link new ones as Finder aliases
  for f in "$NIX_APPS"/*; do
    app_name="$(basename "$f")"
    target_alias="$HOME_APPS/$app_name"

    if [ ! -e "$target_alias" ]; then
      echo "Creating Finder alias for $app_name"
      osascript -e "tell application \"Finder\" to make alias file to POSIX file \"$f\" at POSIX file \"$HOME_APPS\""
    else
      echo "Alias for $app_name already exists"
    fi
  done
fi
