{ pkgs, ... }:

{
  imports = [ ./base.nix ];

  home.packages = with pkgs; [
    gitify
    orbstack

    # The below GIU apps are not available yet via nixpkgs on darwin.
    # - AWS VPN
    # - ZeroTier VPN
  ];

  programs.git = {
    userName = "Austin Benavides";
    userEmail = "7328768+throwandgo@users.noreply.github.com";
    extraConfig.user.signingkey = "5B7E0BFE597FC4AF";
  };
}
