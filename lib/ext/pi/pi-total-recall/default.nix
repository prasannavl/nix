{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-total-recall";
  source = (import ../sources.nix).${pname};
  # The published tarball bundles its three runtime packages (@samfp/pi-memory,
  # pi-session-search, pi-knowledge-search) through bundleDependencies, and its
  # pi manifest points the extensions and the session-history skill at those
  # bundled copies.
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
      description = "Persistent memory, session history and knowledge search stack for Pi";
      homepage = "https://github.com/samfoy/pi-total-recall";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
