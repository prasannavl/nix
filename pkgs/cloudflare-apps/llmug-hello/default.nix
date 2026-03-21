{pkgs}: let
  build = pkgs.runCommand "llmug-hello-dist" {} ''
    src="${./.}"

    mkdir -p "$out"
    cp "$src/index.html" "$src/favicon.ico" "$out/"
    cp -r "$src/css" "$src/js" "$src/icons" "$out/"
  '';
  deployWrangler = pkgs.writeShellApplication {
    name = "llmug-hello-wrangler-deploy";
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
  lint = pkgs.writeShellApplication {
    name = "llmug-hello-lint";
    runtimeInputs = with pkgs; [biome];
    text = ''
      set -euo pipefail

      cd ${./.}
      exec biome check .
    '';
  };
  fix = pkgs.writeShellApplication {
    name = "llmug-hello-fix";
    runtimeInputs = with pkgs; [biome];
    text = ''
      set -euo pipefail

      cd ${./.}
      exec biome check --write .
    '';
  };
in
  build.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        inherit build;
        wrangler-deploy = deployWrangler;
        inherit lint fix;
      };
  })
