{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-25.05-darwin";
    unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
            })
          ];
        };
      };

      mkHome = { username, homeDirectory, machineModule }: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nixpkgsModule
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
