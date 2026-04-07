{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  build = pkgs.runCommand "llmug-hello-dist" {} ''
    src="${./.}"

    mkdir -p "$out"
    cp "$src/index.html" "$src/favicon.ico" "$out/"
    cp -r "$src/css" "$src/js" "$src/icons" "$out/"
  '';
  deployWrangler = pkgs.writeShellApplication {
    name = "llmug-hello-wrangler-deploy";
    meta = {
      description = "Deploy llmug-hello Wrangler worker";
      mainProgram = "llmug-hello-wrangler-deploy";
    };
    runtimeInputs = with pkgs; [
      git
      nix
      wrangler
    ];
    text = ''
      set -euo pipefail

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

      if [ -n "$repo_root" ] && [ -f "$repo_root/pkgs/cloudflare-apps/llmug-hello/default.nix" ]; then
        assets_dir="$(nix build --no-link --print-out-paths --file "$repo_root/pkgs/cloudflare-apps/llmug-hello/default.nix" | tail -n1)"
      else
        assets_dir="$(nix build --no-link --print-out-paths "path:${./.}#build" | tail -n1)"
      fi

      cd ${./.}
      exec wrangler deploy --assets "$assets_dir" "$@"
    '';
  };
  drv = pkgHelper.mkWebDerivation {
    inherit pkgs;
    src = ./.;
    build = build;
    extraDevShellPackages = with pkgs; [
      nix
      wrangler
    ];
  };
in
  pkgHelper.wirePassthru drv {
    wrangler-deploy = deployWrangler;
  }
