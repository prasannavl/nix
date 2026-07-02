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
  nativeClientCaDefaultsStack = import ../stack/lib.nix {
    stackName = "test";
    org = "test";
    env = "test";
    defaultMailDomain = "example.test";
    defaultUser = "svc";
    defaultClientSecretsBasePath = "/secrets/client";
    defaultClientIdentitySuffix = "svc.example";
    defaultServiceIdentitySuffix = "svc.example";
    defaultPostgresUrl = "postgresql://postgres@db:5432/app?sslmode=verify-ca";
    defaultNatsUrl = "tls://nats:4222";
  };
  standardOutputs = flakeLib.standardOutputsFrom [system] {
    ${system} = outputs;
  };
in {
  lib-flake-isolated = assert flakeLib.stacks == {};
  assert outputs.packages ? migration-manager;
  assert outputs.packages.migration-manager.meta.mainProgram == "migratorctl";
  assert nativeClientCaDefaultsStack.defaultCaCertContainerPath == "/run/secrets/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultPostgresCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultNatsCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert standardOutputs.packages.${system} ? migration-manager;
    pkgs.runCommand "lib-flake-isolated-test" {} ''
      touch "$out"
    '';
}
