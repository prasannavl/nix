{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-web";
  source = (import ../sources.nix).${pname};
  releaseSource = pkgs.fetchFromGitHub {
    owner = "agegr";
    repo = "pi-web";
    rev = "v${source.version}";
    hash = source.releaseHash;
  };
  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@agegr/${pname}/-/${pname}-${source.version}.tgz";
    hash = source.srcHash;
  };

  # pi-web's release lockfile lacks resolved/integrity for some bundled deps,
  # which makes prefetch-npm-deps panic. Repair a private copy inside the
  # fixed-output dependency fetch, where the sandbox grants network; both the
  # cache and the main derivation then consume the repaired lock offline.
  npmDeps = pkgs.fetchNpmDeps {
    name = "${pname}-${source.version}-npm-deps";
    inherit src;
    hash = source.npmDepsHash;
    fetcherVersion = 2;
    postPatch = ''
      cp ${releaseSource}/package-lock.json package-lock.json
      chmod u+w package-lock.json
      ${pkgs.lib.getExe pkgs.npm-lockfile-fix} package-lock.json
    '';
  };
in
  pkgs.buildNpmPackage {
    inherit pname npmDeps src;
    inherit (source) version;

    postPatch = ''
      # Adopt the repaired lock from the dependency fetch so npm ci matches the
      # cache instead of the original upstream lockfile.
      cp ${npmDeps}/package-lock.json package-lock.json
    '';

    npmDepsFetcherVersion = 2;

    dontNpmBuild = true;
    dontNpmPrune = true;

    meta = {
      description = "Web interface for the Pi coding agent";
      homepage = "https://github.com/agegr/pi-web";
      license = pkgs.lib.licenses.mit;
      mainProgram = "pi-web";
      platforms = pkgs.lib.platforms.all;
    };
  }
