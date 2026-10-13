# Opt-in execution in independent guest stores; never register as a root check.
{
  pkgs,
  baseline,
  changed,
  seedPaths ? [],
  recipeExpression ? null,
  workspaceCrates ? [],
  expectedCompilations ? {},
  excludedOutputs ? [],
  name ? "rust-foundation-vm",
  memorySize ? 16384,
  cores ? 16,
  buildTimeout ? 300,
  checkDeterminism ? false,
  extraCases ? {},
  comparisonOnly ? false,
  globalTimeout ? 1800,
}: let
  lib = pkgs.lib;
  cases = {inherit baseline changed;} // extraCases;
  identify = item: {
    buildDrv = builtins.unsafeDiscardStringContext item.build.drvPath;
    buildOutput = builtins.unsafeDiscardStringContext item.build.outPath;
    packageDrv = builtins.unsafeDiscardStringContext item.package.drvPath;
    packageOutput = builtins.unsafeDiscardStringContext item.package.outPath;
    inherit (item) mainProgram expectedVersion;
    runtimeChecks = item.runtimeChecks or [];
  };
  spec = pkgs.writeText "rust-foundation-vm-cases.json" (builtins.toJSON {
    cases = builtins.mapAttrs (_: identify) cases;
    excludedOutputs = map builtins.unsafeDiscardStringContext excludedOutputs;
    recipeExpression =
      if recipeExpression == null
      then null
      else toString recipeExpression;
    inherit buildTimeout workspaceCrates expectedCompilations checkDeterminism comparisonOnly;
  });
  # A drvPath's deep context would realize the target on the host. Retain only
  # its recipe file and input recipe/source closure, never its output dependency.
  recipes = lib.concatMap (item: [
    (builtins.unsafeDiscardOutputDependency item.build.drvPath)
    (builtins.unsafeDiscardOutputDependency item.package.drvPath)
  ]) (builtins.attrValues cases);
  node = {...}: {
    nix.enable = true;
    nix.settings = {
      experimental-features = ["nix-command"];
      sandbox = true;
      sandbox-build-dir = "/build";
      sandbox-fallback = false;
      substituters = lib.mkForce [];
      builders = lib.mkForce [];
      allowed-uris = lib.mkForce [];
      allow-import-from-derivation = false;
      build-use-substitutes = false;
      max-jobs = 1;
      cores = cores;
    };
    virtualisation = {
      inherit memorySize cores;
      useNixStoreImage = true;
      mountHostNixStore = false;
      restrictNetwork = true;
      writableStore = true;
      writableStoreUseTmpfs = false;
      diskSize = 32768;
      additionalPaths =
        (
          if recipeExpression == null
          then recipes
          else [recipeExpression]
        )
        ++ seedPaths ++ [spec];
    };
    networking.useDHCP = lib.mkForce false;
    networking.interfaces.eth1.useDHCP = lib.mkForce false;
    environment.systemPackages = [pkgs.nix pkgs.python3 pkgs.coreutils];
  };
in
  assert lib.all (item: lib.isDerivation item.build && lib.isDerivation item.package) (builtins.attrValues cases);
  assert builtins.attrNames extraCases == [] || builtins.attrNames extraCases == ["legacy"];
  assert !comparisonOnly || extraCases ? legacy;
  assert lib.all (item: builtins.match "[a-zA-Z0-9_-]+" item.mainProgram != null) (builtins.attrValues cases);
    pkgs.testers.runNixOSTest {
      name = name;
      globalTimeout = globalTimeout;
      nodes = {warm = node;} // lib.optionalAttrs (!comparisonOnly) {fresh = node;};
      testScript =
        lib.optionalString comparisonOnly "fresh = None\n"
        + "comparison_only = ${
          if comparisonOnly
          then "True"
          else "False"
        }\n"
        + builtins.readFile ./vm_test.py;
      # Only descriptive paths are passed to the driver; target realization belongs
      # to the guest. The spec itself remains an ordinary declared image input.
      extraPythonPackages = _: [];
      defaults.environment.etc."rust-foundation-vm-spec.json".source = spec;
    }
