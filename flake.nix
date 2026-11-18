{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-25.11-darwin";
    unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Spotlight/Raycast-indexable launchers for Nix-installed apps.
    mac-app-util.url = "github:hraban/mac-app-util";
  };

  outputs = { nixpkgs, unstable, home-manager, ... }@inputs:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      nixpkgsModule = {
        nixpkgs = {
          config = {
            allowUnfree = true;
            allowUnfreePredicate = (pkgs: true);
          };
          overlays = [
            (final: prev: {
              unstable = import inputs.unstable {
                system = final.system;
                config.allowUnfree = true;
              };
              # direnv's fish integration test is killed by the macOS sandbox
              direnv = prev.direnv.overrideAttrs (_: { doCheck = false; });

              # nixpkgs is still on 1.0.61. As of 1.0.80 upstream's release
              # tarball is a thin npm-loader.js stub that spawns a separate
              # per-platform native binary shipped as its own npm package, so
              # nixpkgs' old "universal tarball" derivation no longer applies.
              # Fetch the darwin-arm64 platform package directly and run its
              # bundled Mach-O binary in place.
              github-copilot-cli = prev.stdenvNoCC.mkDerivation rec {
                pname = "github-copilot-cli";
                version = "1.0.104";

                src = prev.fetchurl {
                  url = "https://registry.npmjs.org/@github/copilot-darwin-arm64/-/copilot-darwin-arm64-${version}.tgz";
                  hash = "sha256-q/zgRu9RDjEdAAx0kWLzjG0te0huM8xRPvUjRCRM+C4=";
                };

                sourceRoot = "package";
                dontBuild = true;
                dontStrip = true; # preserve the binary's ad-hoc code signature

                installPhase = ''
                  runHook preInstall
                  mkdir -p "$out"/libexec/github-copilot-cli
                  cp -r . "$out"/libexec/github-copilot-cli
                  mkdir -p "$out"/bin
                  ln -s "$out"/libexec/github-copilot-cli/copilot "$out"/bin/copilot
                  runHook postInstall
                '';

                meta = {
                  description = "GitHub Copilot CLI brings the power of Copilot coding agent directly to your terminal";
                  homepage = "https://github.com/github/copilot-cli";
                  changelog = "https://github.com/github/copilot-cli/releases/tag/v${version}";
                  license = prev.lib.licenses.unfree;
                  mainProgram = "copilot";
                  platforms = [ "aarch64-darwin" ];
                };
              };

              herdr = prev.stdenvNoCC.mkDerivation rec {
                pname = "herdr";
                version = "0.9.3";

                src = prev.fetchurl {
                  url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-macos-aarch64";
                  hash = "sha256-UXOj4K5C1dGrfr+l1eYyn3w9I/jho2d8fOMjHaKIQVc=";
                };

                dontUnpack = true;
                dontBuild = true;
                dontStrip = true;

                installPhase = ''
                  runHook preInstall
                  install -Dm755 "$src" "$out/bin/herdr"
                  runHook postInstall
                '';

                meta = {
                  description = "Terminal workspace manager for AI coding agents";
                  homepage = "https://herdr.dev";
                  license = prev.lib.licenses.asl20;
                  mainProgram = "herdr";
                  platforms = [ "aarch64-darwin" ];
                };
              };

              # not yet packaged in nixpkgs: https://github.com/sirmalloc/ccstatusline
              # a single bun-bundled ESM file with no runtime deps, so we just
              # install the prebuilt npm artifact and wrap it with node.
              ccstatusline = prev.stdenvNoCC.mkDerivation rec {
                pname = "ccstatusline";
                version = "2.2.27";

                src = prev.fetchurl {
                  url = "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${version}.tgz";
                  hash = "sha256-T2Cb3tENjBBkUWzvuQLtWTkasru6l9WT6KEtB+LaWMI=";
                };

                nativeBuildInputs = [ prev.makeBinaryWrapper ];

                dontBuild = true;

                installPhase = ''
                  runHook preInstall

                  install -Dm644 dist/ccstatusline.js $out/libexec/ccstatusline/ccstatusline.js
                  makeWrapper ${prev.nodejs}/bin/node $out/bin/ccstatusline \
                    --add-flags $out/libexec/ccstatusline/ccstatusline.js

                  runHook postInstall
                '';

                meta = {
                  description = "Customizable status line formatter for Claude Code";
                  homepage = "https://github.com/sirmalloc/ccstatusline";
                  license = prev.lib.licenses.mit;
                  mainProgram = "ccstatusline";
                };
              };

              # not yet packaged in nixpkgs: https://github.com/simonw/claude-code-transcripts
              claude-code-transcripts = prev.python3Packages.buildPythonApplication rec {
                pname = "claude-code-transcripts";
                version = "0.6";
                pyproject = true;

                src = prev.fetchPypi {
                  pname = "claude_code_transcripts";
                  inherit version;
                  hash = "sha256-xM81zX8Cv2txy1d8CjmtJaGE7q8T7GosjWzcKQAyQ5A=";
                };

                build-system = [ prev.python3Packages.uv-build ];

                dependencies = with prev.python3Packages; [
                  click
                  click-default-group
                  httpx
                  jinja2
                  markdown
                  questionary
                ];

                pythonImportsCheck = [ "claude_code_transcripts" ];

                meta = {
                  description = "Convert Claude Code session files to HTML transcripts";
                  homepage = "https://github.com/simonw/claude-code-transcripts";
                  license = prev.lib.licenses.asl20;
                  mainProgram = "claude-code-transcripts";
                };
              };
            })
          ];
        };
      };

      mkHome = { username, homeDirectory, machineModule }: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nixpkgsModule
          inputs.mac-app-util.homeManagerModules.default
          machineModule
          {
            home.username = username;
            home.homeDirectory = homeDirectory;
            home.stateVersion = "25.05";
          }
        ];
        extraSpecialArgs = { inherit inputs; };
      };
    in
    {
      homeConfigurations = {
        "personal" = mkHome {
          username = "abe";
          homeDirectory = "/Users/abe";
          machineModule = ./home/personal.nix;
        };

        "work" = mkHome {
          username = "ABenavides";
          homeDirectory = "/Users/ABenavides";
          machineModule = ./home/work.nix;
        };
      };
    };
}
