{ pkgs, lib, config, inputs, ... }:

let
  # Claude Code's settings.json is hand-maintained (permissions, hooks, plugins)
  # and Claude Code rewrites it at runtime, so we merge in just the statusLine key
  # rather than letting home-manager own the whole file.
  claudeStatusLineSetup = pkgs.writeShellScript "claude-statusline-setup" ''
    set -euo pipefail
    settings="$1"
    cmd="$2"

    mkdir -p "$(dirname "$settings")"
    [ -e "$settings" ] || printf '{}\n' > "$settings"

    if ! ${pkgs.jq}/bin/jq -e . "$settings" >/dev/null 2>&1; then
      echo "warning: $settings is not valid JSON; leaving statusLine unset" >&2
      exit 0
    fi

    merged="$(${pkgs.jq}/bin/jq --arg cmd "$cmd" \
      '.statusLine = { type: "command", command: $cmd }' "$settings")"

    # Rewrite in place so the file keeps its permissions and stays writable.
    printf '%s\n' "$merged" > "$settings"
  '';
in
{
  home.sessionVariables = {
    EDITOR = "nvim";
    TIG_EDITOR = "nvim";
    XDG_CONFIG_HOME = "${config.home.homeDirectory}/.config";
  };

  home.packages = with pkgs; [
    firefox # browser
    obsidian # notes
    spotify # music streaming
    raycast # spotlight replacement

    # The below GUI apps are not available yet via nixpkgs on darwin.
    # - beeper # messaging
    # - claude # llm
    # - naps2 # scanner utilities

    asciinema # generating gifs from terminal sessions
    asciinema-agg # same as above
    bat # better cat
    ccstatusline # claude code status line
    claude-code # llm programming
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

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;

    config = {
      global = {
        hide_env_diff = true; # silence env var diff when entering directory
      };
    };
  };

  programs.starship.enable = true;

  # Claude Code status line layout. ccstatusline hardcodes this path under $HOME
  # (it ignores XDG_CONFIG_HOME), and home-manager makes it a read-only symlink,
  # so `ccstatusline`'s TUI editor cannot save over it. To experiment, run
  # `ccstatusline --config /tmp/cc.json` and copy the result back here.
  home.file.".config/ccstatusline/settings.json".text = builtins.toJSON {
    version = 3; # matches ccstatusline's CURRENT_VERSION, so it never rewrites this file
    # Catppuccin Frappe (matching wezterm.lua) as "hex:RRGGBB" -- note ccstatusline
    # wants the hex: prefix and no leading '#'. The built-in named colors resolve to
    # a fixed ansi256 palette that is far too dark against Frappe's #303446 base
    # (brightBlack lands at 1.69:1, magenta at 1.87:1). These all clear 5:1.
    lines = [
      [
        { id = "1"; type = "model"; color = "hex:99d1db"; } # sky, 7.33:1
        { id = "2"; type = "separator"; color = "hex:838ba7"; }
        # Denominator is 80% of the window, which is the auto-compact trigger:
        # 100% here means compaction is happening right now. Plain
        # "context-percentage" measures the raw window and reads ~20% lower.
        { id = "3"; type = "context-percentage-usable"; color = "hex:a6d189"; } # green, 7.10:1
        { id = "4"; type = "separator"; color = "hex:838ba7"; }
        { id = "5"; type = "context-length"; color = "hex:a5adce"; } # subtext0, 5.55:1
        { id = "6"; type = "separator"; color = "hex:838ba7"; }
        { id = "7"; type = "compaction-counter"; color = "hex:ef9f76"; } # peach, 5.80:1
        { id = "8"; type = "separator"; color = "hex:838ba7"; }
        { id = "9"; type = "git-branch"; color = "hex:ca9ee6"; } # mauve, 5.60:1
        { id = "10"; type = "separator"; color = "hex:838ba7"; }
        { id = "11"; type = "git-changes"; color = "hex:e5c890"; } # yellow, 7.62:1
      ]
      [ ]
      [ ]
    ];
    colorLevel = 3; # truecolor, so the hex: values are used exactly rather than downsampled
    # Use the full terminal width until context reaches compactThreshold, then
    # leave room for Claude Code's auto-compact warning.
    flexMode = "full-until-compact";
    compactThreshold = 60;
  };

  # After installPackages so the ccstatusline binary the path points at already
  # exists on a first-time sync.
  home.activation.claudeCodeStatusLine =
    lib.hm.dag.entryAfter [ "writeBoundary" "installPackages" ] ''
      run ${claudeStatusLineSetup} \
        "${config.home.homeDirectory}/.claude/settings.json" \
        "${config.home.homeDirectory}/.nix-profile/bin/ccstatusline"
    '';

  programs.zsh = {
    enable = true;
    autocd = true;
    initContent = lib.mkOrder 550 ''
      if [ -f ~/.config/home-manager/extra.zsh ]; then
        source ~/.config/home-manager/extra.zsh
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
      c = "claude";
      v = "nvim";
      vim = "nvim";
      ll = "lsd -l";
    };
  };

  programs.git = {
    enable = true;
    lfs.enable = true;

    settings = {
      alias = {
        current-branch = "rev-parse --abbrev-ref HEAD";
        default-branch = "!git rev-parse --abbrev-ref origin/HEAD | awk -F/ '{print $2}'";
        fresh = "!git switch $(git default-branch) && git pull origin $(git default-branch) && git fetch";
        pushc = "!git push origin $(git current-branch) --force-with-lease";
        pullc = "!git pull origin $(git current-branch)";
        l = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
        find = "log --all --grep -i";
        when = "log -S -i";
      };
      commit.gpgsign = true;
      fetch.writeCommitGraph = true;
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      rebase.autosquash = true;
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
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
