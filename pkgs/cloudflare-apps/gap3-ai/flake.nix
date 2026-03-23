{
  description = "gap3-ai Cloudflare app build";

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
    in {
      packages = {
        default = build;
        inherit build;
        wrangler-deploy = deployWrangler;
      };
      apps = {
        wrangler-deploy = {
          type = "app";
          program = "${deployWrangler}/bin/gap3-ai-wrangler-deploy";
        };
      };
      devShells = {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nix
            wrangler
          ];
        };
      };
    });
}
