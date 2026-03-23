{pkgs}: let
  build = pkgs.runCommand "gap3-ai-dist" {} ''
    src="${./.}"

    mkdir -p "$out"
    cp "$src/index.html" "$out/"
  '';
  deployWrangler = pkgs.writeShellApplication {
    name = "gap3-ai-wrangler-deploy";
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
in
  build.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        inherit build;
        wrangler-deploy = deployWrangler;
      };
  })
