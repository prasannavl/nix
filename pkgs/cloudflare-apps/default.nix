{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../lib/flake/pkg-helper.nix,
  nixbot ? pkgs.callPackage ../nixbot/default.nix {inherit pkgHelper;},
  llmugHello ? pkgs.callPackage ./llmug-hello/default.nix {inherit pkgHelper;},
}: let
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
  pkgHelper.mkAggregateDerivation {
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
      deploy = pkgHelper.mkPackageApp pkgs deploy;
    };
  }
