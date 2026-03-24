{
  description = "cloudflare-apps aggregate build and deploy helpers";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    nixbot = {
      url = "path:../nixbot";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    nixbot,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      llmugHello = pkgs.callPackage ./llmug-hello/default.nix {};
      cloudflareApps = pkgs.callPackage ./default.nix {
        nixbot = nixbot.packages.${system}.default;
        inherit llmugHello;
      };
    in {
      packages = {
        default = cloudflareApps;
        inherit (cloudflareApps) build deploy;
      };
      apps = {
        deploy = {
          type = "app";
          program = "${cloudflareApps.deploy}/bin/cloudflare-apps-deploy";
        };
      };
    });
}
