{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-tool";
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

      # Runtime dependencies are resolved from the published dependency ranges
      # into sources.nix (see ../update.sh); Pi supplies @earendil-works/*,
      # typebox and node builtins itself.
      ${pkgs.lib.concatMapStrings (name: let
          dep = source.deps.${name};
        in ''
          mkdir -p "$root/node_modules/$(dirname ${name})"
          cp -R ${pkgs.fetchzip {
            url = "https://registry.npmjs.org/${name}/-/${builtins.baseNameOf name}-${dep.version}.tgz";
            hash = dep.srcHash;
          }} "$root/node_modules/${name}"
        '')
        (builtins.attrNames source.deps)}

      runHook postInstall
    '';

    meta = {
      description = "Tool management extension for Pi";
      homepage = "https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-tool";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
