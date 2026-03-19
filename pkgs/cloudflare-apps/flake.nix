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
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      childNames = let
        entries = builtins.readDir ./.;
        childDirs = lib.filterAttrs (name: type:
          type == "directory" && builtins.pathExists (./. + "/${name}/flake.nix")) entries;
      in
        builtins.sort builtins.lessThan (lib.attrNames childDirs);
      childPackages = map (name: let
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
      }) childNames;
      buildPaths = lib.filter (drv: drv != null) (map (child:
        if child.packages ? build then child.packages.build else if child.packages ? default then child.packages.default else null
      ) childPackages);
      aggregateBuild =
        if buildPaths == []
        then pkgs.runCommand "cloudflare-apps-empty" {} ''
          mkdir -p "$out"
        ''
        else pkgs.symlinkJoin {
          name = "cloudflare-apps-build";
          paths = buildPaths;
        };
      childNamesArgs = lib.concatStringsSep " " (map lib.escapeShellArg childNames);
      stage = pkgs.writeShellApplication {
        name = "cloudflare-apps-stage";
        runtimeInputs = with pkgs; [git nix];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          child_names=(${childNamesArgs})

          for child_name in "''${child_names[@]}"; do
            child_dir="$repo_root/pkgs/cloudflare-apps/$child_name"
            [ -f "$child_dir/flake.nix" ] || continue
            echo "Staging Cloudflare app: $child_name" >&2
            nix run "path:$child_dir#stage"
          done
        '';
      };
      deploy = pkgs.writeShellApplication {
        name = "cloudflare-apps-deploy";
        runtimeInputs = with pkgs; [git nix];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          "${stage}/bin/cloudflare-apps-stage"
          exec "$repo_root/scripts/nixbot-deploy.sh" --action tf-apps "$@"
        '';
      };
    in {
      packages = {
        default = aggregateBuild;
        build = aggregateBuild;
        stage = stage;
        deploy = deploy;
      };
      apps = {
        default = {
          type = "app";
          program = "${stage}/bin/cloudflare-apps-stage";
        };
        deploy = {
          type = "app";
          program = "${deploy}/bin/cloudflare-apps-deploy";
        };
        stage = {
          type = "app";
          program = "${stage}/bin/cloudflare-apps-stage";
        };
      };
    });
}
