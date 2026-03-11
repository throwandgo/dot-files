{ pkgs, ... }:

{
  imports = [ ./base.nix ];

  home.packages = with pkgs; [
    # work-specific packages
    gitify
  ];

  programs.git = {
    userName = "Austin Benavides";
    userEmail = "7328768+throwandgo@users.noreply.github.com";
    extraConfig.user.signingkey = "5B7E0BFE597FC4AF";
  };
}
