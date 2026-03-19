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
      stageName = "llmug-hello-stage";
      build = pkgs.runCommand "llmug-hello-dist" {} ''
        src="${./.}"

        mkdir -p "$out"
        cp "$src/index.html" "$src/favicon.ico" "$out/"
        cp -r "$src/css" "$src/js" "$src/icons" "$out/"
      '';
      stage = pkgs.writeShellApplication {
        name = stageName;
        runtimeInputs = with pkgs; [git nix];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          app_dir="$repo_root/pkgs/cloudflare-apps/llmug-hello"

          nix build "path:$app_dir#build" --out-link "$app_dir/result"
        '';
      };
      deployWrangler = pkgs.writeShellApplication {
        name = "llmug-hello-wrangler-deploy";
        runtimeInputs = with pkgs; [git wrangler];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          app_dir="$repo_root/pkgs/cloudflare-apps/llmug-hello"

          "${stage}/bin/${stageName}"
          cd "$app_dir"
          exec wrangler deploy --assets result "$@"
        '';
      };
      lint = pkgs.writeShellApplication {
        name = "llmug-hello-lint";
        runtimeInputs = with pkgs; [biome git];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          cd "$repo_root/pkgs/cloudflare-apps/llmug-hello"
          exec biome check .
        '';
      };
      fix = pkgs.writeShellApplication {
        name = "llmug-hello-fix";
        runtimeInputs = with pkgs; [biome git];
        text = ''
          set -euo pipefail

          repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
          cd "$repo_root/pkgs/cloudflare-apps/llmug-hello"
          exec biome check --write .
        '';
      };
    in {
      packages = {
        default = build;
        build = build;
        stage = stage;
        wrangler-deploy = deployWrangler;
        lint = lint;
        fix = fix;
      };
      apps = {
        default = {
          type = "app";
          program = "${stage}/bin/${stageName}";
        };
        stage = {
          type = "app";
          program = "${stage}/bin/${stageName}";
        };
        wrangler-deploy = {
          type = "app";
          program = "${deployWrangler}/bin/llmug-hello-wrangler-deploy";
        };
        lint = {
          type = "app";
          program = "${lint}/bin/llmug-hello-lint";
        };
        fix = {
          type = "app";
          program = "${fix}/bin/llmug-hello-fix";
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
