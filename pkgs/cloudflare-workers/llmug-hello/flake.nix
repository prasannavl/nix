{
  description = "llmug-hello Cloudflare Worker assets build";

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
      wrangler2 = pkgs.writeShellScriptBin "wrangler2" ''
        exec ${pkgs.wrangler}/bin/wrangler "$@"
      '';
      build = pkgs.runCommand "llmug-hello-dist" {} ''
        src="${./.}"

        mkdir -p "$out"
        cp "$src/index.html" "$src/favicon.ico" "$out/"
        cp -r "$src/css" "$src/js" "$src/icons" "$out/"
      '';
      sync = pkgs.writeShellApplication {
        name = "llmug-hello-sync";
        runtimeInputs = with pkgs; [coreutils rsync git];
        text = ''
          set -euo pipefail

          out_path="$1"
          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          target_dir="$repo_root/pkgs/cloudflare-workers/llmug-hello/dist"

          mkdir -p "$target_dir"
          rsync -a --delete "$out_path"/ "$target_dir"/
        '';
      };
      deploy = pkgs.writeShellApplication {
        name = "deploy";
        runtimeInputs = with pkgs; [git nix];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          out_path="$(nix build --print-out-paths "path:$repo_root/pkgs/cloudflare-workers/llmug-hello#build")"
          "${sync}/bin/llmug-hello-sync" "$out_path"

          exec "$repo_root/scripts/nixbot-deploy.sh" --action tf-apps "$@"
        '';
      };
    in {
      packages = {
        default = build;
        build = build;
        deploy = deploy;
      };
      apps = {
        default = {
          type = "app";
          program = "${deploy}/bin/deploy";
        };
        deploy = {
          type = "app";
          program = "${deploy}/bin/deploy";
        };
      };
      devShells = {
        default = pkgs.mkShell {
          packages = with pkgs; [
            biome
            coreutils
            gnumake
            wrangler
            wrangler2
          ];
        };
      };
    });
}
