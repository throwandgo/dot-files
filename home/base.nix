{ pkgs, lib, config, inputs, ... }:

let
  # Copilot's "default" mode uses the terminal's Base-16/ANSI palette. WezTerm
  # supplies that palette through its Catppuccin Frappe color scheme.
  copilotTheme = "default";

  # Hide the native footer fields because Copilot renders them at opposite ends
  # of the terminal. The custom status line below the prompt keeps them together.
  copilotFooter = builtins.toJSON {
    showModelEffort = false;
    showDirectory = false;
    showBranch = false;
    showContextWindow = false;
    showQuota = false;
    showAgent = false;
    showAiUsed = false;
    showCodeChanges = false;
    showUsername = false;
    showSandbox = false;
    showYolo = false;
    showCustom = true;
  };

  copilotStatusLine = pkgs.writeShellScript "copilot-status-line" ''
    set -euo pipefail

    status="$(cat)"
    model="$(${pkgs.jq}/bin/jq -r '.model.display_name // "Unknown model"' <<< "$status")"
    contextRaw="$(${pkgs.jq}/bin/jq -r '.context_window.current_context_used_percentage // .context_window.used_percentage // 0' <<< "$status")"
    aiUsed="$(${pkgs.jq}/bin/jq -r '.ai_used.formatted // "0 AI credits"' <<< "$status")"
    added="$(${pkgs.jq}/bin/jq -r '.cost.total_lines_added // 0' <<< "$status")"
    removed="$(${pkgs.jq}/bin/jq -r '.cost.total_lines_removed // 0' <<< "$status")"
    branch="$(${pkgs.git}/bin/git branch --show-current 2>/dev/null || true)"

    context="$(LC_ALL=C awk -v value="$contextRaw" 'BEGIN {
      if (value !~ /^[0-9]+([.][0-9]+)?$/) value = 0
      value = int(value + 0.5)
      if (value < 0) value = 0
      if (value > 100) value = 100
      print value
    }')"
    contextFilled=$((context * 10 / 100))
    contextEmpty=$((10 - contextFilled))
    contextBar="$(printf '%*s' "$contextFilled" "" | tr ' ' '█')$(printf '%*s' "$contextEmpty" "" | tr ' ' '░')"

    reset='\033[0m'
    muted='\033[38;2;131;139;167m'
    modelColor='\033[38;2;153;209;219m'
    green='\033[38;2;166;209;137m'
    yellow='\033[38;2;229;200;144m'
    red='\033[38;2;231;130;132m'
    mauve='\033[38;2;202;158;230m'

    contextColor="$green"
    [ "$context" -ge 60 ] && contextColor="$yellow"
    [ "$context" -ge 85 ] && contextColor="$red"

    line="$modelColor$model$reset $muted· context$reset $contextColor$context% $contextBar$reset $muted· session$reset $yellow$aiUsed$reset $muted·$reset $green+$added$reset $red-$removed$reset"
    [ -n "$branch" ] && line="$line $muted·$reset $mauve$branch$reset"
    printf '%b\n' "$line"
  '';

  copilotStatusLineConfig = builtins.toJSON {
    type = "command";
    command = "${copilotStatusLine}";
  };

  # Copilot rewrites settings.json at runtime, so manage our setting by merging
  # it during activation instead of making the whole file a read-only symlink.
  copilotSettingsSetup = pkgs.writeShellScript "copilot-settings-setup" ''
    set -euo pipefail

    settings="$1"
    theme="$2"
    footer="$3"
    statusLine="$4"

    mkdir -p "$(dirname "$settings")"
    [ -e "$settings" ] || printf '{}\n' > "$settings"

    if ! ${pkgs.jq}/bin/jq -e . "$settings" >/dev/null 2>&1; then
      echo "warning: $settings is not valid JSON; leaving it unchanged" >&2
      exit 0
    fi

    updated="$(${pkgs.jq}/bin/jq \
      --arg theme "$theme" \
      --argjson footer "$footer" \
      --argjson statusLine "$statusLine" \
      '.theme = $theme | .footer = $footer | .statusLine = $statusLine' \
      "$settings")"
    printf '%s\n' "$updated" > "$settings"
  '';

  # Runs before auto-compaction to record what we were working on. Compaction
  # summarises the conversation and routinely drops the working state, so this
  # both injects it back (additionalContext) and appends a durable copy to a log
  # -- the log matters because we cannot verify that PreCompact honours
  # additionalContext, but the file is useful either way.
  claudePreCompactHook = pkgs.writeShellScript "claude-precompact-snapshot" ''
    set -uo pipefail

    cwd="$(pwd)"
    branch="$(${pkgs.git}/bin/git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'not a repo')"
    changed="$(${pkgs.git}/bin/git status --porcelain 2>/dev/null | head -15 | sed 's/^/  /')"
    [ -z "$changed" ] && changed="  (clean)"

    ctx="Working state at compaction:
      cwd: $cwd
      branch: $branch
    modified files:
    $changed"

    log="$HOME/.claude/compaction-log"
    mkdir -p "$log"
    printf '%s\n%s\n\n' "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" "$ctx" >> "$log/state.log"

    ${pkgs.jq}/bin/jq -nc --arg c "$ctx" '{
      systemMessage: "Compacting -- working state snapshotted to ~/.claude/compaction-log/state.log",
      hookSpecificOutput: { hookEventName: "PreCompact", additionalContext: $c }
    }'
  '';

  # Claude Code's settings.json is hand-maintained (permissions, hooks, plugins)
  # and Claude Code rewrites it at runtime, so we merge in only the keys we own
  # rather than letting home-manager take the whole file. Both merges live in one
  # script so there is no ordering hazard between two writers.
  claudeSettingsSetup = pkgs.writeShellScript "claude-settings-setup" ''
    set -euo pipefail
    settings="$1"
    statusCmd="$2"
    preCompactCmd="$3"

    mkdir -p "$(dirname "$settings")"
    [ -e "$settings" ] || printf '{}\n' > "$settings"

    if ! ${pkgs.jq}/bin/jq -e . "$settings" >/dev/null 2>&1; then
      echo "warning: $settings is not valid JSON; leaving it unchanged" >&2
      exit 0
    fi

    # Drop any previous entry of ours (the store path changes every rebuild, so
    # match on the script name) before re-adding, to stay idempotent without
    # clobbering hand-written PreCompact hooks.
    merged="$(${pkgs.jq}/bin/jq \
      --arg statusCmd "$statusCmd" \
      --arg preCompactCmd "$preCompactCmd" '
      .statusLine = { type: "command", command: $statusCmd }
      # Lets the plan-approval dialog offer "clear context", which clears the
      # conversation and carries the plan forward as an auto-continuation. This is
      # the only built-in path that clears context with a handoff -- no hook can.
      | .showClearContextOnPlanAccept = true
      # Injects the live remaining-context count after each tool result, so Claude
      # can see what the Ctx(u) status line widget shows and call a handoff before
      # auto-compaction fires. The status line itself is UI-only and never reaches
      # the model. Marked @internal and server-gated; if it appears inert, force it
      # with env.CLAUDE_CODE_TOTAL_TOKENS_REMINDER = "countdown", which overrides.
      | .totalTokensReminder = "countdown"
      | .hooks //= {}
      | .hooks.PreCompact = (
          ((.hooks.PreCompact // [])
            | map(select(
                [.hooks[]?.command // ""]
                | map(test("claude-precompact-snapshot")) | any | not
              )))
          + [ { matcher: "auto",
                hooks: [ { type: "command", command: $preCompactCmd } ] } ]
        )
    ' "$settings")"

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
    github-copilot-cli # github copilot cli
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

  # Global Claude Code instructions. Same shape as the extra.zsh hook above: this file
  # is just a pointer, and the real content lives in the repo where git tracks it.
  # CLAUDE.md's @ syntax imports the target the way `source` pulls in extra.zsh.
  home.file.".claude/CLAUDE.md".text = ''
    @${config.home.homeDirectory}/.config/home-manager/claude/CLAUDE.md
  '';

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
      # Second line: quota. These come from api.anthropic.com/api/oauth/usage,
      # authenticated with the OAuth token in the macOS Keychain and cached for
      # 180s. Only the overage pool reports real numbers on this account --
      # weekly/session both return 0, and the API sends no weekly-reset
      # timestamp, so "weekly-reset-timer" would read [Loading] forever. Add
      # { type = "weekly-usage"; metadata = { display = "progress-short"; }; }
      # if a plan starts metering weekly.
      [
        { id = "20"; type = "extra-usage-utilization"; color = "hex:ef9f76"; metadata = { display = "progress-short"; }; }
        { id = "21"; type = "separator"; color = "hex:838ba7"; }
        { id = "22"; type = "extra-usage-remaining"; color = "hex:a6d189"; }
        { id = "23"; type = "separator"; color = "hex:838ba7"; }
        { id = "24"; type = "session-cost"; color = "hex:8caaee"; }
        # Deliberately no reset/block timer here. "reset-timer" counts down the
        # local 5hr rolling block, which never binds on this account (the usage
        # API returns sessionUsage: 0 on every fetch -- spend goes to the overage
        # pool instead). The pool's own reset date, which claude.ai shows, is not
        # displayable: the API sends no reset timestamps and ccstatusline has no
        # extra-usage reset field.
      ]
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
  home.activation.claudeCodeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" "installPackages" ] ''
      run ${claudeSettingsSetup} \
        "${config.home.homeDirectory}/.claude/settings.json" \
        "${config.home.homeDirectory}/.nix-profile/bin/ccstatusline" \
        "${claudePreCompactHook}"
    '';

  home.activation.copilotSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${copilotSettingsSetup} \
        "${config.home.homeDirectory}/.copilot/settings.json" \
        "${copilotTheme}" \
        '${copilotFooter}' \
        '${copilotStatusLineConfig}'
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
      cc = "claude";
      ghcp = "copilot --yolo";
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
