# Cached real construction only: no compilation, reuse or resolved-unit claims.
{pkgs}: let
  helper = import ../../pkg-helper.nix;
  src = ../fixtures/rust-composition;
  context = {inherit pkgs src;};
  args = {
    projectDir = "members/application";
    pname = "application";
  };
  compose = mode: helper.mkRustComposition (context // {baseMode = mode;});
  member = compose "member";
  selected = member.mkRustDerivation args;
  direct = more: helper.mkRustDerivation (context // args // more);
  isolated = member.mkRustDerivation (args // {useWorkspaceDeps = false;});
  directIsolated = direct {useWorkspaceDeps = false;};
  base = member.baseFor args.projectDir;
  branch = member.baseFor "members/branch";
  leaf = member.baseFor "members/leaf";
  opaque = pkgs.runCommand "rust-composition-opaque" {} "touch $out";
  dependency = dir:
    opaque.overrideAttrs (_: {
      passthru = {
        projectDir = dir;
        memberLayer = throw "automatic member selection must not force dependency artifacts";
        rustToolchainId = throw "automatic member selection must not force dependency identity";
      };
    });
  alternative = pkgs.extend (_final: previous: {
    craneLib = previous.craneLib.overrideScope (_f: old: {
      buildDepsOnly = attrs: old.buildDepsOnly (attrs // {postBuild = "echo changed-factory-context";});
    });
  });
  alternateTools = pkgs.symlinkJoin {
    name = "rust-composition-other-tools";
    paths = [pkgs.rustc pkgs.cargo pkgs.clippy pkgs.rustfmt];
  };
  alternateToolchain = {
    provider = "resolved";
    derivation = alternateTools;
  };
  alternateFactory = helper.mkRustComposition (context
    // {
      baseMode = "member";
      toolchain = alternateToolchain;
    });
  alternateBase = alternateFactory.baseFor args.projectDir;
  output = drv: {inherit (drv) drvPath outputName outPath;};
  identities = drv: map output [drv drv.passthru.memberLayer drv.passthru.checks.fmt drv.passthru.checks.lint drv.passthru.checks.test];
  actualAutomatic = member.mkRustDerivation (args
    // {
      toolchain = alternateToolchain;
      internalDeps = map dependency ["members/branch" "members/leaf" "members/middle"];
    });
  actualExplicit = direct {
    toolchain = alternateToolchain;
    base = alternateBase;
    deps = ["members/branch" "members/leaf" "members/middle"];
  };
  alternateLibraryFactory = helper.mkRustComposition (context
    // {
      baseMode = "member";
      pkgs = alternative;
    });
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  rejects = extra: fails (member.mkRustDerivation (args // extra)).drvPath;
  assertions = {
    omittedPackage = identities ((helper.mkRustComposition context).mkRustDerivation args) == identities (direct {});
    nullPackage = identities ((compose null).mkRustDerivation args) == identities (direct {});
    unionPackage = identities ((compose "union").mkRustDerivation args) == identities (direct {});
    isolatedPackage = output isolated == output directIsolated;
    isolatedNoLayer = !(isolated.passthru ? memberLayer) && !(directIsolated.passthru ? memberLayer);
    isolatedChecks = builtins.all (name: output isolated.passthru.checks.${name} == output directIsolated.passthru.checks.${name}) ["fmt" "lint" "test"];
    explicitWorkspaceDisableHonored = builtins.all (mode: let
      chosen = (compose mode).mkRustDerivation (args // {useWorkspaceDeps = false;});
    in
      output chosen
      == output directIsolated
      && !(chosen.passthru ? memberLayer)
      && builtins.all (name: output chosen.passthru.checks.${name} == output directIsolated.passthru.checks.${name}) ["fmt" "lint" "test"]) [null "member" "union"];
    selectorRejected = fails (compose "legacy");
    unsupportedLegacyModeRejected = fails (helper.mkRustComposition (context
      // {
        src = ../fixtures/rust-closures/config;
        baseMode = "legacy";
      }));
    legacyExplicitBaseRejected = fails ((compose "legacy").mkRustDerivation (args // {base = base;})).drvPath;
    legacyBaseForRejected = fails ((compose "legacy").baseFor args.projectDir).drvPath;
    memberAdmitted = selected.passthru.depsBase.drvPath == base.drvPath;
    memberLayerInherits = selected.passthru.memberLayer.cargoArtifacts.drvPath == base.drvPath;
    packageInheritsMember = selected.cargoArtifacts.drvPath == selected.passthru.memberLayer.drvPath;
    automaticParent = base.cargoArtifacts.drvPath == branch.drvPath;
    depthThree = branch.cargoArtifacts.drvPath == leaf.drvPath && leaf.cargoArtifacts == null;
    vendorShared = base.cargoVendorDir.drvPath == leaf.cargoVendorDir.drvPath && selected.cargoVendorDir.drvPath == base.cargoVendorDir.drvPath;
    lockShared = base.cargoLock == leaf.cargoLock && selected.cargoLock == base.cargoLock;
    fullClosureCompleted = (member.mkRustDerivation (args // {deps = ["members/middle"];})).drvPath == selected.drvPath;
    internalLayersNotForced = (member.mkRustDerivation (args // {internalDeps = map dependency ["members/branch" "members/leaf" "members/middle"];})).drvPath == selected.drvPath;
    explicitNullPreserves = (member.mkRustDerivation (args // {base = null;})).drvPath == (direct {base = null;}).drvPath;
    explicitFalsePreserves = (member.mkRustDerivation (args // {useWorkspaceDeps = false;})).drvPath == (direct {useWorkspaceDeps = false;}).drvPath;
    explicitFalseInUnion = ((compose "union").mkRustDerivation (args // {useWorkspaceDeps = false;})).drvPath == (direct {useWorkspaceDeps = false;}).drvPath;
    explicitBasePreserved = builtins.all (mode:
      ((compose mode).mkRustDerivation (args
        // {
          base = base;
          deps = ["members/branch" "members/leaf" "members/middle"];
        })).passthru.depsBase.drvPath
      == base.drvPath) [null "union" "member"];
    explicitBaseFalseWins = builtins.all (mode:
      identities ((compose mode).mkRustDerivation (args
        // {
          base = base;
          deps = ["members/branch" "members/leaf" "members/middle"];
          useWorkspaceDeps = false;
        }))
      == identities selected) [null "union" "member"];
    labelsDoNotHash = (member.mkRustDerivation (args // {baseLabel = "pilot";})).drvPath == selected.drvPath;
    peerRootUnchained = (member.baseFor "members/peer").cargoArtifacts == null;
    equalCyclesUnchained = (member.baseFor "members/cycle-a").cargoArtifacts == null && (member.baseFor "members/cycle-b").cargoArtifacts == null;
    equivalentPackageContextAccepted =
      (member.mkRustDerivation (args
        // {
          pkgs = pkgs.extend (_final: _previous: {rustCompositionUnrelatedMetadata = true;});
        })).drvPath
      == selected.drvPath;
    actualToolchainAutomaticMatchesExplicit = identities actualAutomatic == identities actualExplicit;
    actualToolchainAncestorMatches = actualAutomatic.passthru.depsBase.passthru.rustClosureBaseParent.drvPath == alternateBase.passthru.rustClosureBaseParent.drvPath;
    staleExplicitBaseRejected = rejects {
      toolchain = alternateToolchain;
      base = base;
      deps = ["members/branch" "members/leaf" "members/middle"];
    };
    actualOperationToolsExposed = builtins.all (name: toString actualAutomatic.passthru.actualOperationTools.${name} == toString alternateTools) ["cargo" "rustc" "clippy" "rustfmt"];
    actualFactoryBaseUnchanged = (member.baseFor args.projectDir).drvPath == base.drvPath && alternateBase.drvPath != base.drvPath;
    alternateContextAutomaticMatchesExplicit =
      identities (member.mkRustDerivation (args // {pkgs = alternative;}))
      == identities (direct {
        pkgs = alternative;
        base = alternateLibraryFactory.baseFor args.projectDir;
        deps = ["members/branch" "members/leaf" "members/middle"];
      });
    sourceMismatchRejected = rejects {src = ../fixtures/rust-workspace;};
    opaqueExplicitRejected = rejects {base = opaque;};
    extraSourceRejected = rejects {deps = ["members/peer"];};
    extraInternalSourceRejected = rejects {internalDeps = [dependency "members/peer"];};
    unsupportedBuildAttrsRejected = rejects {buildAttrs.postBuild = "echo unsupported";};
    noPolicyLeakage = !(selected ? baseMode) && !(selected ? diagnostics);
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert (pkgs.craneLib or null) != null;
  assert failed == [] || throw "rust-composition integration failures: ${builtins.concatStringsSep ", " failed}";
    pkgs.runCommand "pvl-rust-composition-integration-test" {
      passthru = {
        inherit assertions;
        assertionCount = builtins.length (builtins.attrNames assertions);
      };
    } ''
      touch "$out"
    ''
