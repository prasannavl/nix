{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-session-manager";
  version = "0.1.0";
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
      hash = "sha256-fOYQP9MgRiWQPkVqrgpiV4fhUoraqGc14wcINJo6GJU=";
    };

    postPatch = ''
      substituteInPlace extensions/session-manager.ts \
        --replace-fail '@mariozechner/pi-tui' '@earendil-works/pi-tui' \
        --replace-fail '@mariozechner/pi-coding-agent' '@earendil-works/pi-coding-agent'
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/pi/packages/${pname}
      cp -R . $out/share/pi/packages/${pname}

      runHook postInstall
    '';

    meta = {
      description = "Interactive session browser extension for Pi";
      homepage = "https://github.com/vahidkowsari/pi-session-manager";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
