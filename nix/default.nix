{
  inputs ? {},
  nixpkgs,
  flake-utils,
  overlays ? [],
  stacks ? {},
  repositoryConfig ? null,
  repositoryChecksFor ? null,
  externalPackagesFor ? _system: {},
}: let
  lib = nixpkgs.lib;
  repoContextFor = import ./repo-context.nix;
  repositoryTestsFn = import ./tests/repository;
  integrationTestsFn = import ./tests;

  ab = import ../ab;
  fallbackOverlays = ab.core.toolchainOverlays {inputs = inputs;};

  engine = ab.repo.flake.outputs {
    inherit lib nixpkgs overlays fallbackOverlays;
    flakeUtils = flake-utils;
    mkApps = ab.core.flake.apps;
    contextFor = pkgs:
      repoContextFor {
        inherit externalPackagesFor pkgs repositoryChecksFor repositoryConfig;
      };
    checksFor = pkgs: ab:
      lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
        (integrationTestsFn {inherit pkgs;})
        // (repositoryTestsFn {inherit pkgs;})
        // (ab.repo.checks or {})
      );
  };
in
  engine
  // {
    inherit stacks;
  }
