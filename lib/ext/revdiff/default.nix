{pkgs ? import <nixpkgs> {}}: let
  source = (import ./sources.nix).revdiff;
  version = source.version;
in
  pkgs.buildGoModule {
    pname = "revdiff";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = source.owner;
      repo = source.repo;
      rev = source.rev;
      hash = source.hash;
    };

    # The upstream repository vendors all dependencies, so build straight from
    # the vendored tree without a separate dependency fetch.
    vendorHash = null;

    # The main package lives in ./app at this revision, so the produced binary
    # is named `app`; rename it to `revdiff`.
    subPackages = ["app"];

    # Tests need a git working tree, which is absent in the Nix sandbox.
    doCheck = false;

    env.CGO_ENABLED = 0;

    # Mirror upstream's Makefile revision injection into package main.
    ldflags = [
      "-s"
      "-w"
      "-X main.revision=${source.rev}"
    ];

    postInstall = ''
      mv $out/bin/app $out/bin/revdiff
    '';

    meta = {
      description = "TUI for reviewing diffs, files, and documents with inline annotations";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = pkgs.lib.licenses.mit;
      mainProgram = "revdiff";
      platforms = pkgs.lib.platforms.all;
    };
  }
