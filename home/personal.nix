{ pkgs, ... }:

{
  imports = [ ./base.nix ];

  home.packages = with pkgs; [
    # personal packages
  ];

  programs.git.settings = {
    user = {
      name = "Austin Benavides";
      email = "7328768+throwandgo@users.noreply.github.com";
      signingkey = "4BD10B2EC93F2CB8";
    };
  };
}
