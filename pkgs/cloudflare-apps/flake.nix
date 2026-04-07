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
      llmugHello = pkgs.callPackage ./llmug-hello/default.nix {};
      baseBuild = pkgs.callPackage ./default.nix {
        nixbot = nixbot.packages.${system}.default;
        llmugHello = llmugHello;
      };
      fmtParts = [
        (pkgHelper.projectFmtGlobal {})
      ];
      fmt = pkgHelper.mkProjectCommandsApp pkgs {
        name = "cloudflare-apps-fmt";
        description = "Format cloudflare-apps";
        src = ./.;
        parts = fmtParts;
        commands = [];
      };
      fmtCheck = pkgHelper.mkProjectCommandsCheck pkgs {
        name = "cloudflare-apps-fmt-check";
        src = ./.;
        parts = fmtParts;
        commands = [];
      };
      drv = pkgHelper.wirePassthru baseBuild.build {
        fmt = fmt;
        checks = {
          fmt = fmtCheck;
        };
      };
    in
      pkgHelper.mkStdFlakeOutputs {
        pkgs = pkgs;
        build = drv;
        extraPackages = {
          deploy = baseBuild.deploy;
        };
        extraApps = {
          deploy = pkgHelper.mkPackageApp pkgs baseBuild.deploy;
        };
      });
}
