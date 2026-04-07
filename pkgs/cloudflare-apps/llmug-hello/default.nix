{pkgs ? import <nixpkgs> {}}: let
  pkgHelper = import ../../../lib/flake/pkg-helper.nix;
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
      nix
      wrangler
    ];
    text = ''
      set -euo pipefail

      assets_dir="$(nix build --no-link --print-out-paths "path:${./.}#build" | tail -n1)"

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
