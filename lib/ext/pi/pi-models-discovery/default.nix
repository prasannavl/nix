{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-models-discovery";
  source = (builtins.fromJSON (builtins.readFile ../sources.json)).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchFromGitHub {
      owner = "maplezzk";
      repo = "pi-extensions";
      inherit (source) rev;
      hash = source.srcHash;
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
