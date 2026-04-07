{pkgs ? import <nixpkgs> {}}: let
  pkgHelper = import ../../lib/flake/pkg-helper.nix;
  drv = pkgHelper.mkStaticWebDerivation {
    inherit pkgs;
    src = ./.;
    pname = "hello-web-static";
    devRoot = "site";
    build = pkgs.stdenvNoCC.mkDerivation {
      pname = "hello-web-static";
      version = "0.1.0";

      src = ./.;

      installPhase = ''
        runHook preInstall

        install -d "$out/share/hello-web-static"
        cp -r site/. "$out/share/hello-web-static/"

        runHook postInstall
      '';

      meta = {
        description = "Static hello-world web site assets";
      };
    };
    enableLint = false;
    enableLintFix = false;
  };
in
  drv
