{
  pkgs,
  ab,
  nixbot ? ../tools/nixbot,
  llmugHello ? ./llmug-hello,
}:
ab.package.withDeps {
  inherit nixbot llmugHello;
} ({
  nixbot,
  llmugHello,
}: let
  deploy = pkgs.writeShellApplication {
    name = "cloudflare-apps-deploy";
    meta = {
      description = "Deploy Cloudflare apps";
      mainProgram = "cloudflare-apps-deploy";
      platforms = pkgs.lib.platforms.linux;
    };
    text = ''
      set -euo pipefail

      exec ${nixbot}/bin/nixbot tf-apps "$@"
    '';
  };
in
  ab.build.aggregate {
    inherit pkgs;
    src = ./.;
    pname = "cloudflare-apps";
    buildPaths = [llmugHello];
    extraPassthru = {
      deploy = deploy;
      llmug-hello = llmugHello;
    };
    extraPackages = {
      deploy = deploy;
    };
    extraApps = {
      deploy = ab.flake.app pkgs deploy;
    };
  })
