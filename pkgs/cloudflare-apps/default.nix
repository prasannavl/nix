{
  pkgs ? import <nixpkgs> {},
  nixbot ? pkgs.callPackage ../nixbot/default.nix {},
  llmugHello ? pkgs.callPackage ./llmug-hello/default.nix {},
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
    meta = {
      description = "Deploy Cloudflare apps";
      mainProgram = "cloudflare-apps-deploy";
    };
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
        deploy = deploy;
        llmug-hello = llmugHello;
      };
  })
