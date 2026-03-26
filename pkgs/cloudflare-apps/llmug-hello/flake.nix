{
  description = "llmug-hello Cloudflare app build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      build = pkgs.callPackage ./default.nix {};
      deployWrangler = build.wrangler-deploy;
      inherit (build) lint fix;
    in {
      packages = {
        default = build;
        build = build;
        wrangler-deploy = deployWrangler;
        inherit lint fix;
      };
      apps = {
        wrangler-deploy = {
          type = "app";
          program = pkgs.lib.getExe deployWrangler;
        };
        lint = {
          type = "app";
          program = pkgs.lib.getExe lint;
        };
        fix = {
          type = "app";
          program = pkgs.lib.getExe fix;
        };
      };
      devShells = {
        default = pkgs.mkShell {
          packages = with pkgs; [
            biome
            nix
            wrangler
          ];
        };
      };
    });
}
