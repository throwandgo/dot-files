{ pkgs, ... }:

{
  imports = [ ./base.nix ];

  home.packages = with pkgs; [
    # work-specific packages
  ];

  programs.git = {
    userName = "Austin Benavides";
    userEmail = "abenavides@metropolis.io";               # ← your work email
    extraConfig.user.signingkey = "WORK_GPG_KEY"; # ← your work GPG key
  };
}
