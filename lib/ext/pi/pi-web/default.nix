{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-web";
  source = (builtins.fromJSON (builtins.readFile ../sources.json)).${pname};
  releaseSource = pkgs.fetchFromGitHub {
    owner = "agegr";
    repo = "pi-web";
    rev = "v${source.version}";
    hash = source.releaseHash;
  };
in
  pkgs.buildNpmPackage {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/@agegr/${pname}/-/${pname}-${source.version}.tgz";
      hash = source.srcHash;
    };

    postPatch = ''
      cp ${releaseSource}/package-lock.json package-lock.json
    '';

    npmDepsFetcherVersion = 2;
    inherit (source) npmDepsHash;

    dontNpmBuild = true;

    meta = {
      description = "Web interface for the Pi coding agent";
      homepage = "https://github.com/agegr/pi-web";
      license = pkgs.lib.licenses.mit;
      mainProgram = "pi-web";
      platforms = pkgs.lib.platforms.all;
    };
  }
