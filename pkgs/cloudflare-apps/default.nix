{
  pkgs,
  nixbot,
  llmugHello,
}: let
  buildPaths = [llmugHello];
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
    text = ''
      set -euo pipefail

      exec ${nixbot}/bin/nixbot tf-apps "$@"
    '';
  };
in
  aggregateBuild.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        build = aggregateBuild;
        inherit deploy;
        llmug-hello = llmugHello;
      };
  })
