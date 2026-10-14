# Cached construction only. Optional mirrorSrc exercises a generated immutable
# revision fixture; default coverage requires no filesystem staging or fetching.
{
  pkgs,
  mirrorSrc ? ./fixtures/exports,
  generatedEntry ? false,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  source = ./fixtures/exports;
  memberDirs = ["members/agent" "members/manager"];
  fakeUtils.lib = {
    defaultSystems = [system];
    eachSystem = systems: fn:
      builtins.foldl' (acc: s:
        builtins.foldl' (a: key: a // {${key} = (a.${key} or {}) // {${s} = (fn s).${key};};}) acc (builtins.attrNames (fn s))) {}
      systems;
  };
  inputs = {
    nixpkgs = {
      lib = pkgs.lib;
      legacyPackages.${system} = pkgs;
    };
    flake-utils = fakeUtils;
  };
  makeOutputs = extra:
    (import ../mirror.nix) ({
        inherit inputs memberDirs;
        src = mirrorSrc;
        primaryMember = "members/manager";
        pkgsForSystem = _: pkgs;
      }
      // extra);
  outputs =
    if generatedEntry
    then (import (mirrorSrc + "/flake.nix")).outputs inputs
    else makeOutputs {};
  library = outputs.lib.${system};
  drv = outputs.packages.${system}.default;
  direct = (import ../export.nix {
    src = source;
    inherit memberDirs;
    packageFile = source + "/members/manager/default.nix";
  }).mkPackage {inherit pkgs;};
  injected = library.mkPackage {
    inherit pkgs;
    base = direct.passthru.depsBase;
  };
  same = a: b: a.drvPath == b.drvPath && a.outputName == b.outputName && a.outPath == b.outPath;
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  member = library.packages.agent.mkPackage {inherit pkgs;};
  exporter = import ../export.nix {
    src = source;
    inherit memberDirs;
    packageFile = source + "/members/manager/default.nix";
  };
  make = extra: exporter.mkPackage ({inherit pkgs;} // extra);
  missingSrc = make {packageArgs.omitSrc = true;};
  sourceOnly = make {packageArgs.agent = null;};
  sourceOnlyMissingSrc = make {
    packageArgs = {
      agent = null;
      omitSrc = true;
    };
  };
  intrinsic = base:
    make {
      base = missingSrc.passthru.depsBase;
      packageArgs.buildArgs.base = base;
    };
  fullExporter = import ../export.nix {
    src = source;
    memberDirs = memberDirs ++ ["members/peer"];
    packageFile = source + "/members/manager/default.nix";
  };
  escaped = fullExporter.mkPackage {
    inherit pkgs;
    packageArgs.buildArgs.base = null;
  };
  compilationAttrs = {
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.openssl];
    env = {
      OPENSSL_DIR = pkgs.openssl;
      OPENSSL_STATIC = "literal$not_a_shell_expansion";
    };
  };
  shellArgs = {
    enableDevShell = true;
    extraDevShellPackages = [pkgs.jq];
    buildAttrs = compilationAttrs;
    extraPassthru = drv: {
      devShell = drv.passthru.devShell.overrideAttrs (_: {
        shellHook = "echo package-owned-hook-must-not-run >&2";
      });
    };
  };
  fixtureOutputs = inputPkgs: buildArgs:
    makeOutputs {
      src = source;
      pkgsForSystem = _:
        inputPkgs
        // {
          inherit buildArgs;
          agent = null;
        };
    };
  ownedOutputs = fixtureOutputs pkgs shellArgs;
  ownedBuild = ownedOutputs.packages.${system}.default;
  ownedShell = ownedBuild.passthru.devShell;
  exportedShell = ownedOutputs.devShells.${system}.default;
  resolvedCompiler = pkgs.symlinkJoin {
    name = "rust-export-recipe-toolchain";
    paths = [pkgs.rustc pkgs.cargo pkgs.clippy pkgs.rustfmt];
  };
  recipeToolchain = {
    provider = "resolved";
    derivation = resolvedCompiler;
  };
  # Distinguish the recipe's actual library from the caller's null selection.
  # The wrapper changes only the bound TOML writer's observable output identity.
  recipePkgs =
    pkgs
    // {
      rustToolchainFor = spec: let
        selected =
          if pkgs ? rustToolchainFor
          then pkgs.rustToolchainFor spec
          else (import ../toolchain.nix {pkgs = pkgs;}).toolchainFor spec;
      in
        if spec == null
        then selected
        else
          selected
          // {
            craneLib = selected.craneLib.overrideScope (_: previous: {
              writeTOML = name: manifest: previous.writeTOML "${name}-actual-recipe-library" manifest;
            });
          };
    };
  recipeBase =
    (helper.forRustSource {
      src = source;
      inherit memberDirs;
    }).mkClosureBase {
      pkgs = recipePkgs;
      src = source;
      projectDir = "members/manager";
      deps = ["members/agent"];
      toolchain = recipeToolchain;
      buildAttrs = compilationAttrs;
    };
  helper = import ../../pkg-helper.nix;
  recipeOutputs = fixtureOutputs recipePkgs (shellArgs
    // {
      toolchain = recipeToolchain;
      base = recipeBase;
      deps = ["members/agent"];
    });
  recipeBuild = recipeOutputs.packages.${system}.default;
  recipeShell = recipeOutputs.devShells.${system}.default;
  automaticRecipeOutputs = fixtureOutputs recipePkgs (shellArgs // {toolchain = recipeToolchain;});
  automaticRecipeBuild = automaticRecipeOutputs.packages.${system}.default;
  automaticRecipeBase =
    (helper.forRustSource {
      src = source;
      inherit memberDirs;
    }).mkRustComposition {
      pkgs = recipePkgs;
      src = source;
      toolchain = recipeToolchain;
      baseMode = "member";
      buildAttrs = compilationAttrs;
    };
  # mkShell may select another output (e.g. jq.bin); inspect selected outputs,
  # not equality of recursive package records or just unselected outPaths.
  contains = inputs: wanted: builtins.any (input: input.drvPath == wanted.drvPath) inputs;
  ownsAll = shell: owner: builtins.all (input: builtins.any (candidate: same candidate input) shell.nativeBuildInputs) owner.nativeBuildInputs;
  ownsCompilerTools = shell: build:
    builtins.all (tool: builtins.any (input: same input tool) shell.nativeBuildInputs)
    (builtins.attrValues build.passthru.actualOperationTools);
  assertions = {
    standaloneRootDirectIdentity = same drv direct;
    actualExternalBaseAdmitted = same drv injected;
    automaticBaseIdentity = same library.depsBase direct.passthru.depsBase;
    defaultLibraryConstructorIdentity = same drv (library.mkPackage {inherit pkgs;});
    memberLibraryConstructorIdentity = same member outputs.packages.${system}.agent;
    defaultStillPrimary = same drv outputs.packages.${system}.manager;
    standardBuildStillPrimary = same drv outputs.packages.${system}.build;
    componentLabelStable = library.component.memberDirs == memberDirs && library.component.packages == ["agent" "manager"];
    ownedAgentBuildCheck = same outputs.checks.${system}.agent-build member;
    ownedManagerBuildCheck = same outputs.checks.${system}.manager-build drv;
    primaryCheckUnchanged = same outputs.checks.${system}.build drv;
    bothFmtChecks = outputs.checks.${system} ? agent-fmt && outputs.checks.${system} ? manager-fmt;
    bothLintChecks = outputs.checks.${system} ? agent-lint && outputs.checks.${system} ? manager-lint;
    bothTestChecks = outputs.checks.${system} ? agent-test && outputs.checks.${system} ? manager-test;
    packageOwnedFmtApps = outputs.apps.${system} ? agent-fmt && outputs.apps.${system} ? manager-fmt;
    formatterExposed = same outputs.formatter.${system} pkgs.alejandra;
    projectedWorkspaceSource = library.workspaceSrc.src.drvPath == drv.src.drvPath;
    projectedWorkspaceMembers = (builtins.fromJSON library.workspaceSrc.projectedManifest.contents).workspace.members == memberDirs;
    projectionDoesNotReplayHooks =
      library.workspaceSrc.buildCommand
      == ''
        mkdir -p "$out"
        cp -a "$src"/. "$out"/
        chmod u+w "$out" "$out/Cargo.toml"
        cp "$projectedManifest" "$out/Cargo.toml"
      '';
    explicitDevShell = pkgs.lib.isDerivation outputs.devShells.${system}.default;
    pristineShellHook = (outputs.devShells.${system}.default.shellHook or "") == "";
    rootManifestVerbatim = builtins.readFile (source + "/Cargo.toml") == builtins.readFile (mirrorSrc + "/Cargo.toml");
    wholeLockVerbatim = builtins.readFile (source + "/Cargo.lock") == builtins.readFile (mirrorSrc + "/Cargo.lock");
    invalidPrimaryRejected = fails (makeOutputs {primaryMember = "members/peer";});
    noImplicitPartialScope = !((import ../closures.nix).plan {src = mirrorSrc;}).supported || builtins.pathExists (mirrorSrc + "/members/peer/Cargo.toml");
    missingSrcDefaultOwnBaseIdentity = same missingSrc (make {
      base = missingSrc.passthru.depsBase;
      packageArgs.omitSrc = true;
    });
    nullIntrinsicDependencyOwnBaseIdentity = same sourceOnly (make {
      base = sourceOnly.passthru.depsBase;
      packageArgs.agent = null;
    });
    nullDependencyMissingSrcOwnBaseIdentity = same sourceOnlyMissingSrc (make {
      base = sourceOnlyMissingSrc.passthru.depsBase;
      packageArgs = {
        agent = null;
        omitSrc = true;
      };
    });
    nullExportStillAutomatic = same missingSrc (make {
      base = null;
      packageArgs.omitSrc = true;
    });
    recipeNullStillEscape = escaped.drvPath != "" && (escaped.passthru.depsBase or null) == null;
    matchingIntrinsicBaseIdentity = same missingSrc (intrinsic missingSrc.passthru.depsBase);
    conflictingIntrinsicDrvPathRejected = fails (intrinsic (missingSrc.passthru.depsBase // {drvPath = "different.drv";}));
    conflictingIntrinsicOutputNameRejected = fails (intrinsic (missingSrc.passthru.depsBase // {outputName = "different";}));
    conflictingIntrinsicOutPathRejected = fails (intrinsic (missingSrc.passthru.depsBase // {outPath = "${missingSrc.passthru.depsBase.outPath}-different";}));
    opaqueIntrinsicBaseRejected = fails (intrinsic (builtins.removeAttrs missingSrc.passthru.depsBase ["type"]));
    requestedOutsideClosureRejected = fails (make {
      base = missingSrc.passthru.depsBase;
      packageArgs.buildArgs.deps = ["members/peer"];
    });
    differentSourceStillRejected = fails (make {
      base = missingSrc.passthru.depsBase;
      packageArgs.buildArgs.src = ./fixtures/composition;
    });
    packageOwnedJqPresent = contains ownedShell.nativeBuildInputs pkgs.jq;
    packageOwnedAnalyzerPresent = contains ownedShell.nativeBuildInputs pkgs.rust-analyzer;
    exportedJqPreserved = contains exportedShell.nativeBuildInputs pkgs.jq;
    exportedAnalyzerPreserved = contains exportedShell.nativeBuildInputs pkgs.rust-analyzer;
    allOwnedShellInputsPreserved = ownsAll exportedShell ownedShell;
    actualOperationInputsPreserved = ownsCompilerTools exportedShell ownedBuild;
    actualNativeInputsPreserved = contains exportedShell.nativeBuildInputs pkgs.pkg-config;
    actualBuildInputsPreserved = contains exportedShell.buildInputs pkgs.openssl;
    actualEnvironmentPreserved = exportedShell.OPENSSL_DIR == ownedBuild.passthru.memberLayer.OPENSSL_DIR;
    environmentNotShellExpanded = exportedShell.OPENSSL_STATIC == compilationAttrs.env.OPENSSL_STATIC;
    ownedHookFixtureNonempty = ownedShell.shellHook != "";
    packageHookNeverReplayed = exportedShell.shellHook == "";
    recipeCompilerBaseIdentity = same recipeOutputs.lib.${system}.depsBase recipeBase;
    automaticRecipeCompilerBaseIdentity = same automaticRecipeOutputs.lib.${system}.depsBase (automaticRecipeBase.baseFor "members/manager");
    automaticRecipeCompilerTools = ownsCompilerTools automaticRecipeOutputs.devShells.${system}.default automaticRecipeBuild;
    automaticRecipeCompilerOwnBaseIdentity = same automaticRecipeBuild (make {
      pkgs = recipePkgs;
      base = automaticRecipeBuild.passthru.depsBase;
      packageArgs = {
        agent = null;
        buildArgs = shellArgs // {toolchain = recipeToolchain;};
      };
    });
    recipeCompilerShellEvaluates = pkgs.lib.isDerivation recipeShell && recipeShell.drvPath != "";
    recipeCompilerSelectedTools = contains recipeShell.nativeBuildInputs resolvedCompiler;
    recipeCompilerOperationInputsPreserved = ownsCompilerTools recipeShell recipeBuild;
    recipeCompilerOwnedInputsPreserved = ownsAll recipeShell recipeBuild.passthru.devShell;
    recipeCompilerNativeContextPreserved = recipeShell.OPENSSL_DIR == recipeBuild.passthru.memberLayer.OPENSSL_DIR;
    recipeCompilerHookNeverReplayed = recipeShell.shellHook == "";
    recipeCompilerActualWriter =
      same recipeOutputs.lib.${system}.workspaceSrc.projectedManifest
      (recipeBuild.passthru.__rustOperationContext.writeTOML "mirror-workspace-Cargo.toml"
        ((builtins.fromTOML (builtins.readFile (source + "/Cargo.toml")))
          // {
            workspace = (builtins.fromTOML (builtins.readFile (source + "/Cargo.toml"))).workspace // {members = memberDirs;};
          }));
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-mirror failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }
