{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-openai-toolkit";
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
      description = "OpenAI provider toolkit extension for Pi";
      homepage = "https://github.com/awoaCrim/pi-openai-toolkit";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
