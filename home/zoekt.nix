# Indexed code search (zoekt) for nvim's grep (nvim/lua/search/zoekt.lua).
#
# Endpoint security (CrowdStrike, JumpCloud) intercepts every file open, so a ripgrep scan of a
# large repo costs ~0.5s however fast rg is. zoekt answers from a trigram index held in memory in
# a few ms and ranks definitions first. It indexes each repo's committed HEAD; nvim greps the files
# changed since then with rg and merges the results.
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.zoekt;
  indexDir = "${config.home.homeDirectory}/.zoekt";
  logDir = "${config.home.homeDirectory}/Library/Logs";

  index = pkgs.writeShellScript "zoekt-index-repos" ''
    set -o errexit -o nounset -o pipefail
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.universal-ctags ]}:$PATH
    for repo in ${lib.escapeShellArgs cfg.repos}; do
      if [[ -d "''${repo}/.git" ]]; then
        # Incremental: a no-op (~0.1s) unless HEAD moved.
        ${pkgs.zoekt}/bin/zoekt-git-index -index ${indexDir} -branches HEAD -parallelism 4 "''${repo}" \
          || echo "zoekt-git-index failed for ''${repo}" >&2
      fi
    done
  '';
in
{
  options.programs.zoekt = {
    enable = lib.mkEnableOption "zoekt code search for nvim";
    port = lib.mkOption {
      type = lib.types.port;
      default = 6070;
      description = "Localhost port of the zoekt webserver (nvim reads vim.g.zoekt_url).";
    };
    repos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Absolute paths of git checkouts to index.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.zoekt pkgs.universal-ctags ];

    launchd.agents.zoekt-webserver = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.zoekt}/bin/zoekt-webserver"
          "-index"
          indexDir
          "-listen"
          "127.0.0.1:${toString cfg.port}"
          "-rpc"
          "-html=false"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardErrorPath = "${logDir}/zoekt-webserver.log";
        StandardOutPath = "${logDir}/zoekt-webserver.log";
      };
    };

    launchd.agents.zoekt-index = {
      enable = true;
      config = {
        ProgramArguments = [ "${index}" ];
        RunAtLoad = true;
        # Reindex when HEAD moves (commit, checkout, pull), plus a periodic safety net.
        WatchPaths = map (repo: "${repo}/.git/logs/HEAD") cfg.repos;
        StartInterval = 1800;
        ThrottleInterval = 30;
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardErrorPath = "${logDir}/zoekt-index.log";
        StandardOutPath = "${logDir}/zoekt-index.log";
      };
    };
  };
}
