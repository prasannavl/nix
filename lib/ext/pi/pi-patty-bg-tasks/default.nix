{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-patty-bg-tasks";
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
      description = "Background tasks extension for Pi with auto-backgrounding";
      homepage = "https://github.com/patty-io/pi-patty-bg-tasks";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
