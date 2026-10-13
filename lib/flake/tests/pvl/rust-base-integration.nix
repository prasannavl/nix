# Cached real-Crane evaluation only. No compilation, fetch or IFD.
{pkgs}: let
  helper = import ../../pkg-helper.nix;
  fixture = ../fixtures/rust-workspace;
  context = {
    inherit pkgs;
    src = fixture;
    projectDir = "members/application";
  };
  base = helper.mkClosureBase context;
  package = args: helper.mkRustDerivation (context // {pname = "application";} // args);
  injected = package {inherit base;};
  fails = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
  rejects = args: fails (package ({inherit base;} // args)).drvPath;
  recipe = base.passthru.rustClosureBaseRecipe;
  cleanedRoot = pkgs.craneLib.cleanCargoToml {cargoToml = fixture + "/Cargo.toml";};
  projectedRoot = pkgs.craneLib.writeTOML "Cargo.toml" (cleanedRoot // {workspace = cleanedRoot.workspace // {members = ["members/application"];};});
  tool = pkgs.symlinkJoin {
    name = "rust-base-toolchain-test";
    paths = [pkgs.rustc pkgs.cargo pkgs.clippy pkgs.rustfmt];
  };
  # Extend the fixed point: shallow merges retain rustToolchainFor bound to the
  # original package set and make override assertions hollow under root overlays.
  alternateCompiler = pkgs.extend (_final: prev: {craneLib = prev.craneLib.overrideToolchain tool;});
  alternateStdenv = pkgs.extend (_final: prev: {craneLib = prev.craneLib.overrideScope (_f: _p: {stdenvSelector = p: p.clangStdenv;});});
  alternateVendor = pkgs.extend (_final: prev: {
    craneLib = prev.craneLib.overrideScope (_f: _p: {
      vendorCargoDeps = _: pkgs.runCommand "rust-base-other-vendor" {} "mkdir -p $out";
    });
  });
  alternateScripts = pkgs.extend (_final: prev: {
    craneLib = prev.craneLib.overrideScope (_f: previous: {
      buildDepsOnly = attrs: previous.buildDepsOnly (attrs // {postBuild = "echo different-bound-script";});
    });
  });
  opaque = pkgs.runCommand "rust-base-opaque" {} "touch $out";
  internal = dir:
    opaque.overrideAttrs (_: {
      passthru = {
        projectDir = dir;
        memberLayer = throw "explicit base must win without forcing dependency layers";
        rustToolchainId = throw "explicit base must not consult dependency identity";
      };
    });
  chainContext =
    context
    // {
      src = ../fixtures/rust-bases;
      deps = ["members/library-a"];
    };
  chainBase = helper.mkClosureBase chainContext;
  subsetContext =
    context
    // {
      src = ../fixtures/rust-base-chains;
      deps = ["members/library-a" "members/library-b"];
    };
  leafContext =
    subsetContext
    // {
      projectDir = "members/library-b";
      deps = [];
    };
  middleContext =
    subsetContext
    // {
      projectDir = "members/library-a";
      deps = ["members/library-b"];
    };
  leaf = helper.mkClosureBase leafContext;
  middle = helper.mkClosureBase (middleContext // {parent = leaf;});
  depthTwo = helper.mkClosureBase (subsetContext // {parent = helper.mkClosureBase middleContext;});
  depthThree = helper.mkClosureBase (subsetContext // {parent = middle;});
  subsetPackage = b: package (subsetContext // {base = b;});
  subsetRejects = b: fails (subsetPackage b).drvPath;
  parentRejects = p: fails (helper.mkClosureBase (subsetContext // {parent = p;})).drvPath;
  swapParent = b: p:
    b.overrideAttrs (old: {
      passthru =
        old.passthru
        // {
          rustClosureBaseParent = p;
          rustClosureBaseRecipe = old.passthru.rustClosureBaseRecipe // {parent = p.passthru.rustClosureBaseRecipe or null;};
        };
    });
  cyclic =
    leaf
    // {
      passthru = {
        rustClosureBaseRecipe =
          leaf.passthru.rustClosureBaseRecipe
          // {
            version = 2;
            parent = cyclic.passthru.rustClosureBaseRecipe;
          };
        rustClosureBaseParent = cyclic;
      };
    };
  malformed = p: leaf.overrideAttrs (_: {passthru.rustClosureBaseRecipe = p;});
  cyclicDescription = depthThree.overrideAttrs (old: {passthru = old.passthru // {rustClosureBaseRecipe = old.passthru.rustClosureBaseRecipe // {parent = cyclicDescription.passthru.rustClosureBaseRecipe;};};});
  equalContext =
    subsetContext
    // {
      projectDir = "members/cycle-a";
      deps = ["members/cycle-b"];
    };
  equalPeer = helper.mkClosureBase (equalContext
    // {
      projectDir = "members/cycle-b";
      deps = ["members/cycle-a"];
    });
  alternateLeaf = helper.mkClosureBase (leafContext // {pkgs = alternateCompiler;});
  alternateMiddle = helper.mkClosureBase (middleContext
    // {
      pkgs = alternateCompiler;
      parent = alternateLeaf;
    });
  alternateTop = helper.mkClosureBase (subsetContext
    // {
      pkgs = alternateCompiler;
      parent = alternateMiddle;
    });
  assertions = {
    bothVersionsShareRootProjection = depthThree.src.buildCommand == (helper.mkClosureBase subsetContext).src.buildCommand;
    explicitNullParentKeepsV1Identity = base.drvPath == (helper.mkClosureBase (context // {parent = null;})).drvPath;
    cyclicDescriptionRejected = subsetRejects cyclicDescription;
    equalDifferentMemberClosureRejected = fails (helper.mkClosureBase (equalContext // {parent = equalPeer;})).drvPath;
    ancestorFullLockTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {cargoLock = opaque;}))));
    noncanonicalAncestorRejected = parentRejects (malformed (leaf.passthru.rustClosureBaseRecipe // {projectDir = "./members/library-b";}));
    malformedNonAttrsRecipeRejected = parentRejects (malformed 42);
    chainMatchedImmutableCompilerAccepted =
      (package (subsetContext
        // {
          pkgs = alternateCompiler;
          base = alternateTop;
        })).passthru.depsBase.drvPath
      == alternateTop.drvPath;
    chainConstructorCompilerMismatchRejected =
      fails
      (helper.mkClosureBase (subsetContext
        // {
          pkgs = alternateCompiler;
          parent = middle;
        })).drvPath;
    depthTwoAdmission = (subsetPackage depthTwo).passthru.depsBase.drvPath == depthTwo.drvPath;
    depthThreeAdmission = (subsetPackage depthThree).passthru.depsBase.drvPath == depthThree.drvPath;
    actualParentInherited = depthThree.cargoArtifacts.drvPath == middle.drvPath && middle.cargoArtifacts.drvPath == leaf.drvPath;
    chainDeterministic = depthThree.drvPath == (helper.mkClosureBase (subsetContext // {parent = middle;})).drvPath;
    chainDiffersFromUnchained = depthThree.drvPath != (helper.mkClosureBase subsetContext).drvPath;
    chainMinimalRecipe = builtins.attrNames depthThree.passthru.rustClosureBaseRecipe == ["parent" "projectDir" "sourceDirs" "version"];
    chainRecursiveRecipe = depthThree.passthru.rustClosureBaseRecipe.parent.parent == leaf.passthru.rustClosureBaseRecipe;
    chainVersion = depthThree.passthru.rustClosureBaseRecipe.version == 2 && middle.passthru.rustClosureBaseRecipe.version == 2;
    chainChecksPrimed = depthThree.doCheck && depthThree.doInstallCargoArtifacts;
    chainMarker = toString depthThree.CRANE_BUILD_DEPS_ONLY == "1";
    chainFaithfulRecipe =
      depthThree.drvPath
      == ((pkgs.craneLib.buildDepsOnly {
        dummySrc = depthThree.src;
        pname = "rust-closure-base";
        version = "2";
        cargoLockContents = builtins.readFile (subsetContext.src + "/Cargo.lock");
        cargoVendorDir = depthThree.cargoVendorDir;
        cargoExtraArgs = "--offline --workspace";
        doCheck = true;
      }).overrideAttrs (_: {cargoArtifacts = middle;})).drvPath;
    chainBuildCommand = pkgs.lib.hasInfix "cargoWithProfile check --offline --workspace --all-targets\ncargoWithProfile build --offline --workspace \n" depthThree.buildPhase;
    chainTestNoRun = pkgs.lib.hasInfix "cargoWithProfile test --offline --workspace --no-run\n" depthThree.checkPhase;
    chainActualDummy = depthThree.src.drvPath == (helper.mkClosureBase subsetContext).src.drvPath && !(depthThree ? dummySrc);
    chainVendorShared = depthThree.cargoVendorDir.drvPath == middle.cargoVendorDir.drvPath && middle.cargoVendorDir.drvPath == leaf.cargoVendorDir.drvPath;
    chainFullLockShared = depthThree.cargoLock == middle.cargoLock && middle.cargoLock == leaf.cargoLock;
    chainChecksInheritLayer = (subsetPackage depthThree).passthru.checks.test.cargoArtifacts.drvPath == (subsetPackage depthThree).passthru.memberLayer.drvPath;
    chainLabelNotHashed =
      (subsetPackage depthThree).drvPath
      == (package (subsetContext
        // {
          base = depthThree;
          baseLabel = "chain-label";
        })).drvPath;
    equalParentRejected = parentRejects (helper.mkClosureBase subsetContext);
    peerParentRejected = parentRejects (helper.mkClosureBase (leafContext // {projectDir = "members/peer";}));
    largerParentRejected = fails (helper.mkClosureBase (middleContext // {parent = depthThree;})).drvPath;
    opaqueParentRejected = parentRejects opaque;
    forgedParentRejected = parentRejects (opaque.overrideAttrs (_: {passthru.rustClosureBaseRecipe = leaf.passthru.rustClosureBaseRecipe;}));
    otherOriginalSourceRejected = parentRejects (helper.mkClosureBase (chainContext
      // {
        projectDir = "members/library-a";
        deps = [];
      }));
    constructorCyclicParentRejected = parentRejects cyclic;
    consumerCyclicParentRejected = subsetRejects (swapParent depthThree (swapParent middle cyclic));
    malformedParentRejected = parentRejects (malformed {
      version = 1;
      projectDir = 42;
      sourceDirs = [];
    });
    malformedDirsRejected = parentRejects (malformed {
      version = 1;
      projectDir = "members/library-b";
      sourceDirs = "not-list";
    });
    malformedDirElementRejected = parentRejects (malformed {
      version = 1;
      projectDir = "members/library-b";
      sourceDirs = [null];
    });
    malformedVersionTwoRejected = parentRejects (malformed (leaf.passthru.rustClosureBaseRecipe
      // {
        version = 2;
        parent = {};
      }));
    unknownParentVersionRejected = parentRejects (malformed (leaf.passthru.rustClosureBaseRecipe // {version = 999;}));
    ancestorNotActualClosureRejected = parentRejects (malformed {
      version = 1;
      projectDir = "members/library-a";
      sourceDirs = ["members/library-a"];
    });
    parentRecipeMismatchRejected = subsetRejects (depthThree.overrideAttrs (old: {passthru = old.passthru // {rustClosureBaseRecipe = old.passthru.rustClosureBaseRecipe // {parent = leaf.passthru.rustClosureBaseRecipe;};};}));
    parentHandleMismatchRejected = subsetRejects (depthThree.overrideAttrs (old: {passthru = old.passthru // {rustClosureBaseParent = leaf;};}));
    missingParentHandleRejected = subsetRejects (depthThree.overrideAttrs (old: {passthru = builtins.removeAttrs old.passthru ["rustClosureBaseParent"];}));
    v1WithParentRejected = parentRejects (leaf.overrideAttrs (old: {passthru = old.passthru // {rustClosureBaseParent = leaf;};}));
    ancestorSourceTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {src = fixture;}))));
    ancestorVendorTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {cargoVendorDir = opaque;}))));
    ancestorCompilerTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (old: {nativeBuildInputs = old.nativeBuildInputs ++ [tool];}))));
    ancestorStdenvTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (helper.mkClosureBase (leafContext // {pkgs = alternateStdenv;}))));
    ancestorFlagsTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {CARGO_ENCODED_RUSTFLAGS = "-Copt-level=1";}))));
    ancestorOutputNameTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {outputName = "other";})));
    ancestorOutPathTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {outPath = opaque.outPath;})));
    ancestorDrvPathTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {drvPath = opaque.drvPath;})));
    middleFlagsTamperRejected = subsetRejects (swapParent depthThree (middle.overrideAttrs (_: {CARGO_ENCODED_RUSTFLAGS = "other";})));
    chainConsumerCompilerMismatchRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          pkgs = alternateCompiler;
        })).drvPath;
    chainConsumerVendorMismatchRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          pkgs = alternateVendor;
        })).drvPath;
    chainConsumerStdenvMismatchRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          pkgs = alternateStdenv;
        })).drvPath;
    chainConsumerNativeStillRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          nativeCheckInputs = [pkgs.pkg-config];
        })).drvPath;
    chainConsumerHooksStillRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          prePatch = "echo unexpected";
        })).drvPath;
    defaultNullBuildEquality = (package {}).drvPath == (package {base = null;}).drvPath;
    defaultNullLayerEquality = (package {}).passthru.memberLayer.drvPath == (package {base = null;}).passthru.memberLayer.drvPath;
    defaultNullTestEquality = (package {}).passthru.checks.test.drvPath == (package {base = null;}).passthru.checks.test.drvPath;
    validAdmission = injected.passthru.memberLayer.cargoArtifacts.drvPath == base.drvPath;
    packageInheritsLayer = injected.cargoArtifacts.drvPath == injected.passthru.memberLayer.drvPath;
    checksInheritLayer = injected.passthru.checks.test.cargoArtifacts.drvPath == injected.passthru.memberLayer.drvPath;
    vendorMatches = injected.cargoVendorDir.drvPath == base.cargoVendorDir.drvPath;
    lockMatches = injected.cargoLock == base.cargoLock;
    unchained = base.cargoArtifacts == null;
    releaseProfile =
      !(base ? CARGO_PROFILE)
      && base.drvPath
      == (pkgs.craneLib.buildDepsOnly {
        dummySrc = base.src;
        pname = "rust-closure-base";
        version = "1";
        cargoLockContents = builtins.readFile (fixture + "/Cargo.lock");
        cargoVendorDir = base.cargoVendorDir;
        cargoExtraArgs = "--offline --workspace";
        doCheck = true;
      }).drvPath;
    checksPrimed = base.doCheck && base.doInstallCargoArtifacts;
    faithfulBuildCommand = pkgs.lib.hasInfix "cargoWithProfile check --offline --workspace --all-targets\ncargoWithProfile build --offline --workspace \n" base.buildPhase;
    faithfulCheckCommand = pkgs.lib.hasInfix "cargoWithProfile test --offline --workspace --no-run\n" base.checkPhase;
    depsMarker = toString base.CRANE_BUILD_DEPS_ONLY == "1";
    actualDummySrc = base.src.type == "derivation" && base.src.name == "cargo-workspace-source" && pkgs.lib.hasInfix "Cargo.toml" base.src.buildCommand && base.src.drvPath != injected.src.drvPath;
    projectedDummyRoot =
      pkgs.lib.hasInfix (builtins.unsafeDiscardStringContext ''
        chmod u+w "$out/Cargo.toml"
        cp ${projectedRoot} "$out/Cargo.toml"
      '')
      base.src.buildCommand;
    labelDoesNotHash =
      injected.drvPath
      == (package {
        inherit base;
        baseLabel = "diagnostics";
      }).drvPath;
    labelDoesNotHashChecks =
      injected.passthru.checks.lint.drvPath
      == (package {
        inherit base;
        baseLabel = "other";
      }).passthru.checks.lint.drvPath;
    sharedBaseAbsent = !(injected.passthru ? sharedDepsBase);
    opaqueRejected = rejects {base = opaque;};
    forgedMetadataRejected = rejects {base = opaque.overrideAttrs (_: {passthru.rustClosureBaseRecipe = recipe;});};
    unknownRecipeRejected = rejects {base = base.overrideAttrs (_: {passthru.rustClosureBaseRecipe = recipe // {version = 999;};});};
    sourceSelectionForgeryRejected = rejects {base = base.overrideAttrs (_: {passthru.rustClosureBaseRecipe = recipe // {sourceDirs = ["members/library-a"];};});};
    realVendorOverrideRejected = rejects {base = base.overrideAttrs (_: {cargoVendorDir = opaque;});};
    realCompilerOverrideRejected = rejects {base = base.overrideAttrs (old: {nativeBuildInputs = old.nativeBuildInputs ++ [tool];});};
    realSourceOverrideRejected = rejects {base = base.overrideAttrs (_: {src = fixture;});};
    realStdenvOverrideRejected = rejects {base = helper.mkClosureBase (context // {pkgs = alternateStdenv;});};
    realFlagsOverrideRejected = rejects {base = base.overrideAttrs (_: {CARGO_ENCODED_RUSTFLAGS = "-Copt-level=1";});};
    realNativeOverrideRejected = rejects {base = base.overrideAttrs (old: {nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.pkg-config];});};
    consumerCompilerMismatchRejected = rejects {pkgs = alternateCompiler;};
    consumerVendorMismatchRejected = rejects {pkgs = alternateVendor;};
    consumerBoundStdenvMismatchRejected = rejects {pkgs = alternateStdenv;};
    consumerBoundScriptsMismatchRejected = rejects {pkgs = alternateScripts;};
    matchedBoundCompilerAccepted =
      (package {
        pkgs = alternateCompiler;
        base = helper.mkClosureBase (context // {pkgs = alternateCompiler;});
      }).passthru.depsBase.drvPath
      == (helper.mkClosureBase (context // {pkgs = alternateCompiler;})).drvPath;
    functionStdenvAttrRejected = rejects {buildAttrs.stdenv = p: p.stdenv;};
    consumerNativeRejected = rejects {nativeCheckInputs = [pkgs.pkg-config];};
    consumerFlagsRejected = rejects {cargoBuildArgs = ["-p" "application" "--locked"];};
    consumerCheckEnvRejected = rejects {checkEnv.CARGO_ENCODED_RUSTFLAGS = "-Copt-level=1";};
    suppliedBuildRejected = rejects {build = opaque;};
    missingCraneRejected = rejects {pkgs = pkgs.extend (_final: _prev: {craneLib = null;});};
    sourceDirValidation = rejects {internalDeps = [(internal "members/missing")];};
    extraSourceDirValidation = rejects {deps = ["members/library-a"];};
    precedenceWithoutLayersOrJoin =
      (package {
        src = chainContext.src;
        base = chainBase;
        internalDeps = [(internal "members/library-a") (internal "members/library-a")];
      }).passthru.memberLayer.cargoArtifacts.drvPath
      == chainBase.drvPath;
    missingClosureRejected = rejects {
      src = chainContext.src;
      base = chainBase;
    };
    outputSelectionRejected = rejects {base = base // {outputName = "other";};};
    outPathRejected = rejects {base = base // {outPath = opaque.outPath;};};
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert (pkgs.craneLib or null) != null;
  assert builtins.length (builtins.attrNames assertions) == 105;
  assert failed == [] || throw "rust-base integration failures: ${builtins.concatStringsSep ", " failed}";
    pkgs.runCommand "pvl-rust-base-integration-test" {
      passthru = {
        inherit assertions;
        assertionCount = builtins.length (builtins.attrNames assertions);
      };
    } ''
      touch "$out"
    ''
