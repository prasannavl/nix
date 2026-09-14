{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-models-discovery";
  version = "1.2.0";
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname version;

    src = pkgs.fetchFromGitHub {
      owner = "maplezzk";
      repo = "pi-extensions";
      rev = "00bcad50f3e29865efcc8ae13be19bedd16206e0";
      hash = "sha256-rq4GpokUe6WTe9N89P7cWZT4AyHeHXSfPZGXWerrxr0=";
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      packageRoot="$out/share/pi/packages/${pname}"
      mkdir -p "$packageRoot/node_modules"
      cp -R packages/${pname}/. "$packageRoot"
      cp -R packages/pi-extensions-i18n \
        "$packageRoot/node_modules/pi-extensions-i18n"

      runHook postInstall
    '';

    meta = {
      description = "Dynamic provider model discovery extension for Pi";
      homepage = "https://github.com/maplezzk/pi-extensions/tree/main/packages/pi-models-discovery";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
