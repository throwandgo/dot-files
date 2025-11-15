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
      pushc = "!git push origin $(git current-branch) --force-with-lease";
      pullc = "!git pull origin $(git current-branch)";
      l = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
      find = "log --all --grep -i";
      when = "log -S -i";
    };

    delta = {
      enable = true;
      options = {
        navigate = true;
        line-numbers = false;
        side-by-side = false;

        syntax-theme = "none";

        file-style = "bold yellow";
        file-decoration-style = "yellow ol ul";
        file-added-label = "+";
        file-modified-label = "~";
        file-removed-label = "-";

        hunk-header-style = "file line-number";
        hunk-header-decoration-style = "none";

        line-numbers-minus-style = "red";
        line-numbers-plus-style = "green";
        line-numbers-zero-style = "dim";

        minus-style = "red";
        minus-emph-style = "red bold";
        plus-style = "green";
        plus-emph-style = "green bold";


      };
    };

    lfs.enable = true;

    extraConfig = {
      commit.gpgsign = true;
      fetch.writeCommitGraph = true;
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      rebase.autosquash = true;
      user.signingkey = "4BD10B2EC93F2CB8";
    };
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

  services.macos-remap-keys = {
    enable = true;
    keyboard = {
      Capslock = "Escape";
    };
  };

  # MacOS system preferences.
  # See: https://nix-community.github.io/home-manager/options.xhtml#opt-targets.darwin.defaults.
  targets.darwin.defaults = {
    NSGlobalDomain = {
      KeyRepeat = 2;  # 2 ms between repeats
      InitialKeyRepeat = 15;  # 15 ms to begin repeating
      ApplePressAndHoldEnabled = false; # disable press-and-hold for accents
      "com.apple.trackpad.scaling" = 2; # tracking speed
    };
  };
}
