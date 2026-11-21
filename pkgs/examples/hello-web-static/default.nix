{
  pkgs,
  ab,
}: let
  drv = ab.build.staticWeb {
    inherit pkgs;
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
