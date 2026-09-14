{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-tps";
  source = (import ../sources.nix).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchFromGitHub {
      owner = "summertime-wu";
      repo = "pi-tps";
      inherit (source) rev;
      hash = source.srcHash;
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
