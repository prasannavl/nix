{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).awl;
in
  stdenvNoCC.mkDerivation {
    pname = "awl";
    version = source.version;

    src = fetchurl {
      url = "https://gitlab.com/${source.project}/-/archive/${source.tagPrefix}${source.version}/awl-${source.tagPrefix}${source.version}.tar.gz";
      hash = source.hash;
    };

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/awl
      cp -R inc $out/share/awl/inc
      runHook postInstall
    '';

    meta = {
      description = "Andrew's Web Libraries PHP support library";
      homepage = "https://gitlab.com/davical-project/awl";
      license = lib.licenses.gpl2Plus;
      platforms = lib.platforms.all;
    };
  }
