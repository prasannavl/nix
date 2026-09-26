{pkgs ? import <nixpkgs> {}}: let
  source = (import ./sources.nix).revdiff;
  pname = "revdiff-pi";
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    version = source.piVersion;

    src = pkgs.fetchFromGitHub {
      owner = source.owner;
      repo = source.repo;
      rev = source.rev;
      hash = source.hash;
    };

    dontBuild = true;

    installPhase = ''
            runHook preInstall

            packageRoot="$out/share/pi/packages/${pname}"
            mkdir -p "$packageRoot/plugins"
            cp -R plugins/pi "$packageRoot/plugins/pi"
            chmod 0755 "$packageRoot/plugins/pi/scripts/detect-ref.sh"

            # Pi's auto-discovered global extensions directory does not expand a
            # package manifest entry that points at a directory, and its module loader
            # cannot import a bare directory. Point the manifest at the extension file
            # so the directory install resolves, while keeping the upstream
            # plugins/pi layout for the extension's relative script lookup.
            cat >"$packageRoot/package.json" <<EOF
      {
        "name": "${pname}",
        "version": "${source.piVersion}",
        "private": true,
        "pi": {
          "extensions": ["./plugins/pi/extensions/revdiff.ts"]
        }
      }
      EOF

            runHook postInstall
    '';

    meta = {
      description = "Pi package for revdiff interactive diff review";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
