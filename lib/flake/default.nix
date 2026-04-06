{
  nixpkgs,
  flake-utils,
}: let
  appsFn = import ./apps.nix;
  checksFn = import ./checks.nix;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
in rec {
  apps = appsFn;
  checks = checksFn;
  lint = lintFn;
  packages = packagesFn;

  withPkgs = pkgs: let
    lint = lintFn {inherit pkgs;};
    packages = packagesFn {
      inherit pkgs lint;
    };
    apps = appsFn {
      packageSet = packages;
      lint = lint;
    };
  in {
    inherit apps lint packages;
    inherit (lint) formatter;
  };

  withPkgsFor = systems:
    nixpkgs.lib.genAttrs systems (system: withPkgs nixpkgs.legacyPackages.${system});

  standardOutputsFor = systems:
    flake-utils.lib.eachSystem systems (system: let
      outputs = withPkgs nixpkgs.legacyPackages.${system};
    in {
      inherit (outputs) apps formatter packages;
    });

  packagesFor = systems:
    nixpkgs.lib.mapAttrs (_: outputs: outputs.packages) (withPkgsFor systems);
}
