{
  fetchurl,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "awl";
  version = "0.64";

  src = fetchurl {
    url = "https://gitlab.com/davical-project/awl/-/archive/r0.64/awl-r0.64.tar.gz";
    hash = "sha256-lcL1VjZ+SL2LDcgU7VyPRV049XtUoFjNk3L6Zw4LjZc=";
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
