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
      pkgHelper = import ../../lib/flake/pkg-helper.nix;
      drv = pkgs.callPackage ./default.nix {
        nixbot = nixbot.packages.${system}.default;
      };
    in
      pkgHelper.mkStdFlakeOutputs {
        inherit pkgs;
        build = drv;
      });
}
