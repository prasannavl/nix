{
  nixpkgs,
  flake-utils,
}: let
  appsFn = import ./apps.nix;
  pkgHelperFn = import ./pkg-helper.nix;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
in rec {
  apps = appsFn;
  checks = pkgHelperFn;
  lint = lintFn;
  packages = packagesFn;

  withPkgs = pkgs: let
    basePackages = packagesFn {
      inherit pkgs;
    };
    lint = lintFn {
      inherit pkgs;
      packageSet = basePackages.stdPackages;
      pkgHelper = pkgHelperFn;
    };
    packages = (builtins.removeAttrs basePackages ["stdPackages"]) // lint.packages;
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
