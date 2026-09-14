{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-web";
  version = "0.9.1";
  releaseSource = pkgs.fetchFromGitHub {
    owner = "agegr";
    repo = "pi-web";
    rev = "v${version}";
    hash = "sha256-fuuFKezb58lO2P1t3yHIkHPnBe8D8es6TTsqOy7UL7w=";
  };
in
  pkgs.buildNpmPackage {
    inherit pname version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/@agegr/${pname}/-/${pname}-${version}.tgz";
      hash = "sha256-JRINZkuuU3u453EH+aL+UOK/9dzk46yKadxYAy6d6JM=";
    };

    postPatch = ''
      cp ${releaseSource}/package-lock.json package-lock.json
    '';

    npmDepsFetcherVersion = 2;
    npmDepsHash = "sha256-309IHTP/YC0OU8Z4SNUBksRbVFCUAhKsQjl3ef3d034=";

    dontNpmBuild = true;

    meta = {
      description = "Web interface for the Pi coding agent";
      homepage = "https://github.com/agegr/pi-web";
      license = pkgs.lib.licenses.mit;
      mainProgram = "pi-web";
      platforms = pkgs.lib.platforms.all;
    };
  }
