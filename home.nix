{ pkgs, lib, config, inputs, ... }:

{
  home.sessionVariables = {
    EDITOR = "nvim";
    TIG_EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    OVERCOMMIT_COLOR = 0;
  };

  home.packages = with pkgs; [
    firefox # browser
    spotify # music streaming

    asciinema # generating gifs from terminal sessions
    asciinema-agg # same as above
    bat # better cat
    coreutils # gnu core utilities
    devenv # nix dev env
    fd # better find
    fx # interactive jq
    fzf # fuzzy finding across projects
    git-absorb # better git fixup
    gh # github cli
    gnupg # gpg signing
    htop # better top
    jq # json viewing and querying
    lazygit # interactive git tree viewer
    lsd # better ls
    lua # lang suppuort
    lua51Packages.luarocks-nix # manage lua packages via nix
    pass # passwords and gpg signing
    selene # fast lua linter
    ripgrep # better grep
    tig # better git cli
    wezterm # terminal emulator
    zoxide # cd with memory

    unstable.neovim # editor
    unstable.nixpkgs-fmt # nix formatter
    unstable.nerd-fonts.hasklug # font with icons/glyphs
    unstable.tree-sitter # parsing library for syntax highlighting
  ];

  programs.home-manager.enable = true;

  programs.direnv.enable = true;

  programs.starship.enable = true;

  programs.zsh = {
    enable = true;
    autocd = true;
    initContent = lib.mkOrder 550 ''
      if [ -f ~/.config/extra.zsh ]; then
        source ~/.config/extra.zsh
      fi
    '';
    history.ignoreSpace = true;
    antidote = {
      enable = true;
      plugins = [
        "zsh-users/zsh-completions kind:fpath"
        "zsh-users/zsh-autosuggestions kind:defer"
        "zdharma-continuum/fast-syntax-highlighting kind:defer"

        # OMZ
        "getantidote/use-omz" # handle OMZ dependencies
        "ohmyzsh/ohmyzsh path:lib" # load OMZ's library
        "ohmyzsh/ohmyzsh path:plugins/git"
        "ohmyzsh/ohmyzsh path:plugins/dirhistory"
      ];
    };
    shellAliases = {
      v = "nvim";
      vim = "nvim";
      ll = "lsd -l";
    };
  };

  programs.git = {
    enable = true;
    userName = "Austin Benavides";
    userEmail = "7328768+throwandgo@users.noreply.github.com";

    aliases = {
      current-branch = "rev-parse --abbrev-ref HEAD";
      default-branch = "!git rev-parse --abbrev-ref origin/HEAD | awk -F/ '{print $2}'";
      fresh = "!git switch $(git default-branch) && git pull origin $(git default-branch) && git fetch";
      pushc = "!git push origin $(git current-branch)";
      pullc = "!git pull origin $(git current-branch)";
      amend-date = ''!LC_ALL=C GIT_COMMITTER_DATE="$(date)" git commit -n --amend --no-edit --date "$(date)"'';
    };

    extraConfig = {
      init.defaultBranch = "main";
      rebase.autosquash = true;
      fetch.writeCommitGraph = true;
      push.autoSetupRemote = true;
      commit.gpgsign = true;
      user.signingkey = "4BD10B2EC93F2CB8";
      delta.side-by-side = true;
      delta.line-numbers = false;
    };

    diff-so-fancy.enable = true;
    lfs.enable = true;
  };

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    extraConfig = ''set -ag terminal-overrides ",xterm*:Tc"'';
    plugins = [
      pkgs.tmuxPlugins.sensible
      pkgs.tmuxPlugins.vim-tmux-navigator
      pkgs.tmuxPlugins.yank
      {
        plugin = pkgs.tmuxPlugins.dracula;
        extraConfig = ''
          set -g @dracula-show-left-icon session
          set -g @dracula-show-flags true
          set -g @dracula-military-time true
          set -g @dracula-plugins "time"
        '';
      }
    ];
  };

  programs.zellij = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 28800;
    enableSshSupport = true;
    pinentry = {
      package = pkgs.pinentry_mac;
    };
  };

  # MacOS system preferences.
  # See: https://nix-community.github.io/home-manager/options.xhtml#opt-targets.darwin.defaults.
  targets.darwin = {
    defaults = {
      NSGlobalDomain = {
        KeyRepeat = 2;  # 2 ms between repeats
        InitialKeyRepeat = 15;  # 15 ms to begin repeating
        ApplePressAndHoldEnabled = false; # disable press-and-hold for accents
        "com.apple.trackpad.scaling" = 2; # tracking speed
      };
    };

  };
}
