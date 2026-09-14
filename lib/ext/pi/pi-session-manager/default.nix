{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-session-manager";
  source = (builtins.fromJSON (builtins.readFile ../sources.json)).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${source.version}.tgz";
      hash = source.srcHash;
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
