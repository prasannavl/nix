{
  externalPackagesFor ? _system: {},
  pkgs,
  repositoryChecksFor ? null,
  repositoryConfig ? null,
}: let
  checksFor =
    if repositoryChecksFor == null && repositoryConfig == null
    then null
    else
      {
        pkgs,
        lib,
        packageSet,
      }:
        lib.optionalAttrs (repositoryConfig != null) {
          lib-flake-repository-config = import ../ab/repo/tests/repository-config.nix {
            inherit pkgs repositoryConfig;
          };
        }
        // (
          if repositoryChecksFor == null
          then {}
          else repositoryChecksFor {inherit pkgs lib packageSet;}
        );
  ab = (import ../ab).withRepository (
    {
      root = ../.;
      manifest = import ../pkgs/manifest.nix;
      treefmtConfig = ../treefmt.toml;
      tasks = {
        fmtScript = ../scripts/fmt.sh;
        lintScript = ../scripts/lint.sh;
      };
      inherit externalPackagesFor;
    }
    // (
      if checksFor == null
      then {}
      else {inherit checksFor;}
    )
  );
in
  ab.forPkgs {pkgs = pkgs;}
