{pkgs}: let
  system = pkgs.stdenv.hostPlatform.system;
  fakeFlakeUtils = {
    lib = {
      defaultSystems = [system];
      eachSystem = systems: f: let
        outputsBySystem = builtins.listToAttrs (
          map (name: {
            inherit name;
            value = f name;
          })
          systems
        );
        outputNames = pkgs.lib.unique (
          builtins.concatMap (name: builtins.attrNames outputsBySystem.${name}) systems
        );
      in
        builtins.listToAttrs (
          map (outputName: {
            name = outputName;
            value = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = outputsBySystem.${name}.${outputName};
              })
              systems
            );
          })
          outputNames
        );
    };
  };
  flakeLib = import ../default.nix {
    inputs = {};
    nixpkgs = {lib = pkgs.lib;};
    flake-utils = fakeFlakeUtils;
    overlays = [];
    stackProfiles = {};
  };
  outputs = flakeLib.withPkgs pkgs;
  standardOutputs = flakeLib.standardOutputsFrom [system] {
    ${system} = outputs;
  };
in {
  lib-flake-isolated = assert flakeLib.stacks == {};
  assert outputs.packages ? migration-manager;
  assert outputs.packages.migration-manager.meta.mainProgram == "migratorctl";
  assert standardOutputs.packages.${system} ? migration-manager;
    pkgs.runCommand "lib-flake-isolated-test" {} ''
      touch "$out"
    '';
}
