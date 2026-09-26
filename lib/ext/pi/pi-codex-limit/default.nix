{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-codex-limit";
  source = (import ../sources.nix).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${source.version}.tgz";
      hash = source.srcHash;
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/pi/packages/${pname}
      cp -R . $out/share/pi/packages/${pname}

      runHook postInstall
    '';

    meta = {
      description = "Codex subscription usage footer widget extension for Pi";
      homepage = "https://github.com/santychuy/pi-setup/tree/main/extensions/codex-limit";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
