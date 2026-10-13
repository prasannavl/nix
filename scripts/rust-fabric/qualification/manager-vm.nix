# Opt-in VM adapter. Host and guest instantiate the exact same manager recipe
# module with explicit immutable public snapshots and pinned package inputs.
# The caller materializes only the declared Rust workspace and these five public
# support files: lib/flake/{pkg-helper,rust-closures,rust-compile-context,
# member-bases,rust-toolchain}.nix. Never snapshot the live repository wholesale.
#
# import ./manager-vm.nix {
#   pkgs = originalVMDriverPkgs;
#   pkgsPath = /nix/store/<pinned-nixpkgs-source>;
#   cranePath = /nix/store/<pinned-crane-source>;
#   recipeSupportSrc = /nix/store/<declared-public-helper-snapshot>;
#   baselineSrc = /nix/store/<public-baseline-workspace>;
#   changedSrc = /nix/store/<public-changed-workspace>;
#   seedPaths = reviewedCompilerVendorAndNativeInputs;
# }
#
# Only source snapshots and caller-declared tool/vendor output closures enter
# guest seeds. No tested Cargo output or bootstrap .drv closure is seeded. The
# driver instantiates recipes in each guest and checks exact host drv identity
# before its complete seed-output absence gate or any build.
{
  pkgs,
  pkgsPath,
  cranePath,
  recipeSupportSrc,
  baselineSrc,
  changedSrc,
  seedPaths,
  qualificationToolingSrc ? null,
  name ? "rust-foundation-manager-vm",
  memorySize ? 16384,
  cores ? 16,
  buildTimeout ? 300,
  checkDeterminism ? false,
  baselineRuntimeChecks ? [],
  changedRuntimeChecks ? [],
}: let
  lib = pkgs.lib;
  repository = ../../..;
  fail = message: throw "rust-foundation-manager-vm: ${message}";
  inputGuard =
    if
      lib.all (path: builtins.isPath path && lib.hasPrefix "${builtins.storeDir}/" (toString path) && builtins.pathExists path) [pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc]
      && (qualificationToolingSrc == null || (builtins.isPath qualificationToolingSrc && lib.hasPrefix "${builtins.storeDir}/" (toString qualificationToolingSrc) && builtins.pathExists qualificationToolingSrc))
    then true
    else fail "recipe inputs must be existing explicit immutable public store snapshots";
  sameFile = left: right: relative:
    builtins.pathExists (left + "/${relative}")
    == builtins.pathExists (right + "/${relative}")
    && (
      !builtins.pathExists (left + "/${relative}")
      || builtins.readFile (left + "/${relative}") == builtins.readFile (right + "/${relative}")
    );
  supportFiles = map (name: "lib/flake/${name}") [
    "pkg-helper.nix"
    "rust-closures.nix"
    "rust-compile-context.nix"
    "member-bases.nix"
    "rust-toolchain.nix"
  ];
  originalFiles = [
    "Cargo.toml"
    "Cargo.lock"
    ".cargo/config"
    ".cargo/config.toml"
    "pkgs/tools/abird-host-agent/Cargo.toml"
    "pkgs/tools/abird-host-agent/default.nix"
    "pkgs/tools/abird-host-manager/Cargo.toml"
    "pkgs/tools/abird-host-manager/default.nix"
  ];
  originalGuard =
    if
      lib.all (relative: sameFile repository recipeSupportSrc relative) supportFiles
      && lib.all (src: lib.all (relative: sameFile repository src relative) originalFiles) [baselineSrc changedSrc]
    then true
    else fail "public snapshots must preserve current helper support, original constructors, full lock/manifests and Cargo configuration";
  arguments = {
    inherit pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc qualificationToolingSrc;
    system = pkgs.stdenv.hostPlatform.system;
  };
  recipes = import ./manager-recipes.nix arguments;
  # Preserve literal module bytes in the public seed closure. Every import in
  # this module is explicit; its store-file location cannot change the recipes.
  recipeModule = pkgs.writeText "rust-foundation-manager-recipes.nix" (builtins.readFile ./manager-recipes.nix);
  expressionArgument = name: path: "${name} = /. + ${builtins.toJSON (toString path)};";
  recipeExpression = pkgs.writeText "rust-foundation-manager-guest-expression.nix" ''
    let recipes = import ${recipeModule} {
      ${lib.concatStringsSep "\n" (map (name: expressionArgument name arguments.${name}) ["pkgsPath" "cranePath" "recipeSupportSrc" "baselineSrc" "changedSrc"])}
      ${
      if qualificationToolingSrc == null
      then "qualificationToolingSrc = null;"
      else expressionArgument "qualificationToolingSrc" qualificationToolingSrc
    }
      system = ${builtins.toJSON arguments.system};
    }; in {
      baseline = recipes.baseline;
      changed = recipes.changed;
    }
  '';
  # Nix path values can be copied under a new source name during coercion.
  # Preserve the exact registered root context, while recipe arguments retain
  # their original subdirectory paths inside the public source bundle.
  storeRootString = path: let
    relative = lib.removePrefix "${builtins.storeDir}/" (toString path);
    rootName = builtins.head (lib.splitString "/" relative);
  in "${builtins.storeDir}/${rootName}";
  storeRoot = path: builtins.storePath (storeRootString path);
  evaluationSources = lib.unique (map storeRoot ([pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc] ++ lib.optional (qualificationToolingSrc != null) qualificationToolingSrc)) ++ [recipeModule];
  seedRoot = path:
    if lib.isDerivation path
    then path
    else storeRoot path;
  seedGuard =
    if !builtins.isList seedPaths || !lib.all (path: lib.isDerivation path || builtins.isPath path || builtins.isString path) seedPaths
    then fail "seedPaths must be an explicit list of public store roots"
    else if !lib.all (path: lib.hasPrefix "${builtins.storeDir}/" (toString path)) seedPaths
    then fail "seed roots must already name store paths; no host directory mounts"
    else if lib.any (path: builtins.elem (builtins.unsafeDiscardStringContext (storeRootString path)) recipes.excludedOutputs) seedPaths
    then fail "seed inventory contains a tested package or Cargo/member artifact output"
    else true;
  vm = import ./vm-test.nix {
    inherit pkgs recipeExpression name memorySize cores buildTimeout checkDeterminism;
    inherit (recipes) workspaceCrates expectedCompilations;
    baseline = recipes.baseline // {runtimeChecks = baselineRuntimeChecks;};
    changed = recipes.changed // {runtimeChecks = changedRuntimeChecks;};
    excludedOutputs = recipes.excludedOutputs;
    seedPaths = lib.unique (evaluationSources ++ map seedRoot seedPaths);
  };
in
  builtins.seq inputGuard (builtins.seq originalGuard (builtins.seq recipes (builtins.seq seedGuard (
    vm
    // {
      passthru =
        (vm.passthru or {})
        // {
          managerQualification = {
            inherit checkDeterminism;
            inherit recipeExpression evaluationSources qualificationToolingSrc;
            inherit (recipes) qualificationCargo;
            inherit (recipes) memberDirs excludedOutputs controls inputs workspaceCrates expectedCompilations;
            cases = {
              baseline = recipes.baseline;
              changed = recipes.changed;
            };
            sourceEditProvidedByCaller = true;
            guestRecipeIdentityCheckRequired = true;
            cargoFreshness = "not_observed";
            qualification = "not_proven";
            defaultAdoption = false;
          };
        };
    }
  ))))
