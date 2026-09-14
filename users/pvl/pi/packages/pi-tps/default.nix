{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-tps";
  version = "1.0.1";
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname version;

    src = pkgs.fetchFromGitHub {
      owner = "summertime-wu";
      repo = "pi-tps";
      rev = "a769402bb27232a3875b9d9ec2df08a0c85d227c";
      hash = "sha256-3NqPujlpb2KRWehdK17k4YCP4G+eLCnP9EWZYM5IAEY=";
    };

    postPatch = ''
      substituteInPlace extensions/pi-tps.ts \
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
      description = "TPS statistics and waterfall trace extension for Pi";
      homepage = "https://github.com/summertime-wu/pi-tps";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
