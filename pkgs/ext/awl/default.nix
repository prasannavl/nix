{
  fetchurl,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "awl";
  version = "0.65";

  src = fetchurl {
    url = "https://gitlab.com/davical-project/awl/-/archive/r0.65/awl-r0.65.tar.gz";
    hash = "sha256-dv61h6ZoJYBofWUfSWvJqg0IWOQJ/HgsgXNfNkLMHFk=";
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
