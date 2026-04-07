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
      pkgHelper = import ../../../lib/flake/pkg-helper.nix;
      drv = pkgs.callPackage ./default.nix {};
    in
      pkgHelper.mkStdFlakeOutputs {
        inherit pkgs;
        build = drv;
        inherit (drv) devShell;
        extraPackages = {
          "wrangler-deploy" = drv.wrangler-deploy;
        };
        extraApps = {
          "wrangler-deploy" = pkgHelper.mkPackageApp pkgs drv.wrangler-deploy;
        };
      });
}
