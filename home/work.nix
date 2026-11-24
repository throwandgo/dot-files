{ config, pkgs, ... }:

{
  imports = [ ./base.nix ./zoekt.nix ];

  programs.zoekt = {
    enable = true;
    repos = [
      "${config.home.homeDirectory}/site"
      "${config.home.homeDirectory}/web"
    ];
  };

  home.packages = with pkgs; [
    awscli2 # aws cli
    chess-tui # terminal chess against Stockfish
    claude-code-transcripts # convert claude code sessions to html transcripts
    gitify # github notification app
    helmfile # declarative spec for deploying helm charts
    kubernetes-helm # helm cli
    orbstack # lightweight docker desktop replacement
    ssm-session-manager-plugin # aws ssm
    stockfish # chess engine
    tenv # terraform/opentofu/terragrunt/atmos version manager (tfenv's nixpkgs successor)
    uv # python package manager

    # The below GUI apps are not available yet via nixpkgs on darwin.
    # - AWS VPN
    # - ZeroTier VPN
  ];

  # helm plugins aren't picked up from home.packages -- helm loads them from
  # its plugins dir (HELM_PLUGINS, ~/Library/helm/plugins on macOS), so link
  # the plugin's store output there directly.
  home.file."Library/helm/plugins/helm-diff".source =
    "${pkgs.kubernetes-helmPlugins.helm-diff}/helm-diff";

  # Metals injects sbt-bloop via project/metals.sbt. Combined with a plugin that
  # leaks a non-provided sbt dependency (site legacy pins sbt-dependency-tree
  # 1.9.0), resolution puts sbt/librarymanagement 1.9.0 on the build-definition
  # classpath and build.sbt fails to compile ("Switch build server" in nvim).
  # Global plugins join every meta-build's resolution, so pinning sbt to the
  # running version evicts the stale copy without touching any repo.
  home.file.".sbt/1.0/plugins/pin-sbt.sbt".text = ''
    libraryDependencies += "org.scala-sbt" % "sbt" % sbtVersion.value
  '';

  programs.git = {
    settings.user = {
      name = "Austin Benavides";
      email = "7328768+throwandgo@users.noreply.github.com";
      signingkey = "5B7E0BFE597FC4AF";
    };
  };
}
