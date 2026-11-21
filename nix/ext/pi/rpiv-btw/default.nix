{pkgs ? import <nixpkgs> {}}: let
  pname = "rpiv-btw";
  source = (import ../sources.nix).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/${source.package}/-/${builtins.baseNameOf source.package}-${source.version}.tgz";
      hash = source.srcHash;
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      root="$out/share/pi/packages/${pname}"
      mkdir -p "$root"
      cp -R . "$root"

      runHook postInstall
    '';

    meta = {
      description = "Side-question (/btw) command extension for Pi";
      homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-btw";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
