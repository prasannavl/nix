{
  pkgs,
  ab,
}: let
  build = pkgs.runCommand "llmug-hello-dist" {} ''
    src="${./.}"

    mkdir -p "$out"
    cp "$src/index.html" "$src/favicon.ico" "$out/"
    cp -r "$src/css" "$src/js" "$src/icons" "$out/"
  '';
  dev = pkgs.writeShellApplication {
    name = "llmug-hello-dev";
    meta = {
      description = "Preview llmug-hello built static assets locally";
      mainProgram = "llmug-hello-dev";
    };
    runtimeInputs = [pkgs.python3];
    text = ''
      set -euo pipefail

      port="8080"
      bind="127.0.0.1"

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --port)
            shift
            port="$1"
            ;;
          --bind)
            shift
            bind="$1"
            ;;
          *)
            printf '%s\n' "Unknown argument: $1" >&2
            exit 1
            ;;
        esac
        shift
      done

      cd ${build}
      exec python -m http.server "$port" --bind "$bind"
    '';
  };
  deployWrangler = pkgs.writeShellApplication {
    name = "llmug-hello-wrangler-deploy";
    meta = {
      description = "Deploy llmug-hello Wrangler worker";
      mainProgram = "llmug-hello-wrangler-deploy";
      platforms = pkgs.lib.platforms.linux;
    };
    runtimeInputs = [pkgs.wrangler];
    text = ''
      set -euo pipefail

      cd ${./.}
      exec wrangler deploy --assets ${build} "$@"
    '';
  };
  drv = ab.build.web {
    inherit pkgs;
    src = ./.;
    build = build;
    extraDevShellPackages = with pkgs; [
      nix
      wrangler
    ];
  };
in
  ab.package.wire drv {
    dev = dev;
    wrangler-deploy = deployWrangler;
  }
