{ pkgs, ... }:

{
  imports = [ ./base.nix ];

  home.packages = with pkgs; [
    obsidian
  ];

  programs.git = {
    userName = "Austin Benavides";
    userEmail = "7328768+throwandgo@users.noreply.github.com";
    extraConfig.user.signingkey = "4BD10B2EC93F2CB8";
  };
}
