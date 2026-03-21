{
  description = "cloudflare-apps aggregate build and deploy helpers";

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
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.${system};
      childNames = let
        entries = builtins.readDir ./.;
        childDirs = lib.filterAttrs (name: type:
          type == "directory" && builtins.pathExists (./. + "/${name}/flake.nix"))
        entries;
      in
        builtins.sort builtins.lessThan (lib.attrNames childDirs);
      childPackages =
        map (name: let
          childFlake = import (./. + "/${name}/flake.nix");
          childOutputs = childFlake.outputs {
            inherit nixpkgs flake-utils;
            self = null;
          };
        in {
          inherit name;
          packages =
            if childOutputs ? packages && builtins.hasAttr system childOutputs.packages
            then childOutputs.packages.${system}
            else {};
        })
        childNames;
      buildPaths = lib.filter (drv: drv != null) (map (
          child:
            child.packages.build or (child.packages.default or null)
        )
        childPackages);
      aggregateBuild =
        if buildPaths == []
        then
          pkgs.runCommand "cloudflare-apps-empty" {} ''
            mkdir -p "$out"
          ''
        else
          pkgs.symlinkJoin {
            name = "cloudflare-apps-build";
            paths = buildPaths;
          };
      deploy = pkgs.writeShellApplication {
        name = "cloudflare-apps-deploy";
        runtimeInputs = with pkgs; [git];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          exec "$repo_root/scripts/nixbot-deploy.sh" --action tf-apps "$@"
        '';
      };
    in {
      packages = {
        default = aggregateBuild;
        build = aggregateBuild;
        inherit deploy;
      };
      apps = {
        deploy = {
          type = "app";
          program = "${deploy}/bin/cloudflare-apps-deploy";
        };
      };
    });
}
