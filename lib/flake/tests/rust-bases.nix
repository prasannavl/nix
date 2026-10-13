# Pure construction/admission checks; mocks are not evidence of real reuse.
let
  helper = import ../pkg-helper.nix;
  fixture = ./fixtures/rust-workspace;
  mkDrv = name: attrs: let
    hash = builtins.substring 0 32 (builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs attrs ["passthru"])));
    path = "/nix/store/${hash}-${name}";
  in
    attrs
    // {
      type = "derivation";
      outPath = path;
      drvPath = "${path}.drv";
      outputName = "out";
      overrideAttrs = f: mkDrv name (attrs // f attrs);
    };
  library = label: let
    build = name: attrs: mkDrv name (attrs // {library = label;});
  in {
    overrideToolchain = tool: library tool.outPath;
    cleanCargoToml = {cargoToml}: builtins.fromTOML (builtins.readFile cargoToml);
    writeTOML = name: data: (build name {inherit data;}) // {inherit data;};
    mkDummySrc = attrs: build "dummy" (attrs // {buildCommand = attrs.extraDummyScript or "";});
    vendorCargoDeps = build "vendor";
    buildDepsOnly = attrs:
      build "deps" ((builtins.removeAttrs attrs ["dummySrc"])
        // {
          src = attrs.dummySrc;
          cargoArtifacts = null;
          env.CRANE_BUILD_DEPS_ONLY = 1;
          doInstallCargoArtifacts = true;
        });
    buildPackage = build "package";
    cargoBuild = build "member";
    cargoFmt = build "fmt";
    cargoClippy = build "lint";
    cargoTest = build "test";
    mkCargoDerivation = attrs:
      if attrs.src == null
      then throw "join must not be forced"
      else build "chained" attrs;
  };
  pkgs = {
    craneLib = library "default";
    stdenv = {
      buildPlatform.system = "x86_64-linux";
      hostPlatform.system = "x86_64-linux";
    };
    cargo = mkDrv "cargo" {};
    rustc = mkDrv "rustc" {};
    clippy = mkDrv "clippy" {};
    rustfmt = mkDrv "rustfmt" {};
    runCommandLocal = name: attrs: script: mkDrv name (attrs // {inherit script;});
    runCommand = name: attrs: script: mkDrv name (attrs // {inherit script;});
    writeShellApplication = attrs: mkDrv attrs.name attrs;
    nix-gitignore.gitignoreFilterPure = _: _: _: _: _: true;
    lib = {
      optional = c: v:
        if c
        then [v]
        else [];
      optionals = c: v:
        if c
        then v
        else [];
      unique = vs:
        builtins.foldl' (acc: v:
          if builtins.elem v acc
          then acc
          else acc ++ [v]) []
        vs;
      splitString = sep: text: builtins.filter builtins.isString (builtins.split sep text);
    };
  };
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
  forged = recipe: (mkDrv "opaque" {}).overrideAttrs (_: {passthru.rustClosureBaseRecipe = recipe;});
  internal = dir:
    mkDrv "dep" {
      passthru = {
        projectDir = dir;
        memberLayer = throw "dependency layer must not be forced";
        rustToolchainId = throw "dependency identity must not be forced";
      };
    };
  depBase = helper.mkClosureBase (context // {projectDir = "members/library-a";});
  chainContext =
    context
    // {
      src = ./fixtures/rust-bases;
      deps = ["members/library-a"];
    };
  chainBase = helper.mkClosureBase chainContext;
  subsetContext =
    context
    // {
      src = ./fixtures/rust-base-chains;
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
  # Runnable, no-realisation fixture: use the helper's actual extra script,
  # exposed as src.buildCommand by a light fake Crane. Its writer only needs
  # the virtual workspace root used by this fixture, not real Cargo or remarshal.
  scriptLibrary =
    (library "source-script")
    // {
      writeTOML = name: data:
        assert builtins.attrNames data == ["workspace"];
          builtins.toFile name ''
            [workspace]
            resolver = ${builtins.toJSON data.workspace.resolver}
            members = ${builtins.toJSON data.workspace.members}
          '';
    };
  scriptContext = subsetContext // {pkgs = pkgs // {craneLib = scriptLibrary;};};
  scriptLeaf = helper.mkClosureBase (leafContext // {pkgs = scriptContext.pkgs;});
  scriptUnchained = helper.mkClosureBase scriptContext;
  scriptChained = helper.mkClosureBase (scriptContext // {parent = scriptLeaf;});
  scriptExpectedRoot = scriptLibrary.writeTOML "Cargo.toml" {
    workspace = {
      resolver = "2";
      members = scriptUnchained.passthru.rustClosureBaseRecipe.sourceDirs;
    };
  };
  assertions = {
    bothVersionsShareRootProjection = (helper.mkClosureBase subsetContext).src.buildCommand == depthThree.src.buildCommand;
    explicitNullParentKeepsV1Identity = base.drvPath == (helper.mkClosureBase (context // {parent = null;})).drvPath;
    cyclicDescriptionRejected = subsetRejects cyclicDescription;
    equalDifferentMemberClosureRejected = fails (helper.mkClosureBase (equalContext // {parent = equalPeer;})).drvPath;
    ancestorFullLockTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {cargoLockContents = "version = 4";}))));
    noncanonicalAncestorRejected = parentRejects (malformed (leaf.passthru.rustClosureBaseRecipe // {projectDir = "./members/library-b";}));
    malformedNonAttrsRecipeRejected = parentRejects (malformed 42);
    depthTwoAdmission = (subsetPackage depthTwo).passthru.depsBase.drvPath == depthTwo.drvPath;
    depthThreeAdmission = (subsetPackage depthThree).passthru.depsBase.drvPath == depthThree.drvPath;
    actualParentInherited = depthThree.cargoArtifacts.drvPath == middle.drvPath && middle.cargoArtifacts.drvPath == leaf.drvPath;
    chainDeterministic = depthThree.drvPath == (helper.mkClosureBase (subsetContext // {parent = middle;})).drvPath;
    chainDiffersFromUnchained = depthThree.drvPath != (helper.mkClosureBase subsetContext).drvPath;
    chainMinimalRecipe = builtins.attrNames depthThree.passthru.rustClosureBaseRecipe == ["parent" "projectDir" "sourceDirs" "version"];
    chainRecursiveRecipe = depthThree.passthru.rustClosureBaseRecipe.parent.parent == leaf.passthru.rustClosureBaseRecipe;
    chainVersion = depthThree.passthru.rustClosureBaseRecipe.version == 2 && middle.passthru.rustClosureBaseRecipe.version == 2;
    chainMarker = depthThree.env.CRANE_BUILD_DEPS_ONLY == 1;
    chainPriming = depthThree.doCheck && depthThree.doInstallCargoArtifacts && depthThree.buildPhaseCargoCommand == "cargoWithProfile check --offline --workspace --all-targets\ncargoWithProfile build --offline --workspace \n" && depthThree.checkPhaseCargoCommand == "cargoWithProfile test --offline --workspace --no-run\n";
    chainActualDummy =
      depthThree.src.drvPath
      == (pkgs.craneLib.mkDummySrc {
        src = depthThree.src.src;
        extraDummyScript = depthThree.src.extraDummyScript;
      }).drvPath
      && !(depthThree ? dummySrc);
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
    opaqueParentRejected = parentRejects (mkDrv "opaque-parent" {});
    forgedParentRejected = parentRejects (forged leaf.passthru.rustClosureBaseRecipe);
    otherOriginalSourceRejected = parentRejects depBase;
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
    ancestorVendorTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {cargoVendorDir = mkDrv "other-vendor" {};}))));
    ancestorCompilerTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {library = "other-compiler";}))));
    ancestorStdenvTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {stdenv = "other-stdenv";}))));
    ancestorFlagsTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf.overrideAttrs (_: {CARGO_ENCODED_RUSTFLAGS = "-Copt-level=1";}))));
    ancestorOutputNameTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {outputName = "other";})));
    ancestorOutPathTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {outPath = "/nix/store/other";})));
    ancestorDrvPathTamperRejected = subsetRejects (swapParent depthThree (swapParent middle (leaf // {drvPath = "/nix/store/other.drv";})));
    middleFlagsTamperRejected = subsetRejects (swapParent depthThree (middle.overrideAttrs (_: {CARGO_ENCODED_RUSTFLAGS = "other";})));
    chainConsumerCompilerMismatchRejected =
      fails
      (package (subsetContext
        // {
          base = depthThree;
          pkgs = pkgs // {craneLib = library "other-compiler";};
        })).drvPath;
    nullDefaultDrvEquality =
      (package {}).drvPath
      == (package {
        base = null;
        baseLabel = "unused";
      }).drvPath;
    nullDefaultCheckEquality = (package {}).passthru.checks.test.drvPath == (package {base = null;}).passthru.checks.test.drvPath;
    validAdmission = injected.passthru.memberLayer.cargoArtifacts.drvPath == base.drvPath;
    baseExposed = injected.passthru.depsBase.drvPath == base.drvPath;
    sharedBaseAbsent = !(injected.passthru ? sharedDepsBase);
    labelDoesNotHash =
      injected.drvPath
      == (package {
        inherit base;
        baseLabel = "diagnostic";
      }).drvPath;
    labelExposed =
      (package {
        inherit base;
        baseLabel = "diagnostic";
      }).passthru.baseLabel
      == "diagnostic";
    labelNotInput = !(injected ? base) && !(injected ? baseLabel) && !(base ? baseLabel);
    unchained = base.cargoArtifacts == null;
    priming = base.cargoExtraArgs == "--offline --workspace" && base.doCheck && base.doInstallCargoArtifacts;
    marker = base.env.CRANE_BUILD_DEPS_ONLY == 1;
    actualDummy =
      base.src.drvPath
      == (pkgs.craneLib.mkDummySrc {
        src = base.src.src;
        extraDummyScript = base.src.extraDummyScript;
      }).drvPath;
    dummyProjectionIsHelperOwned =
      base.src.extraDummyScript
      == ''
        chmod u+w "$out/Cargo.toml"
        cp ${pkgs.craneLib.writeTOML "Cargo.toml" ((builtins.fromTOML (builtins.readFile (fixture + "/Cargo.toml")))
          // {
            workspace = {
              resolver = "2";
              members = ["members/application"];
            };
          })} "$out/Cargo.toml"
      '';
    minimalRecipe = builtins.attrNames recipe == ["projectDir" "sourceDirs" "version"];
    versionedRecipe = recipe.version == 1;
    opaqueRejected = rejects {base = mkDrv "opaque" {};};
    nonDerivationRejected = rejects {base = "opaque";};
    certificateRejected = rejects {base = forged (recipe // {rustToolchainId = "pretend";});};
    forgedRecipeRejected = rejects {base = forged recipe;};
    unknownVersionRejected = rejects {base = base.overrideAttrs (_: {passthru.rustClosureBaseRecipe = recipe // {version = 2;};});};
    wrongDirsRejected = rejects {base = depBase;};
    outputSelectionRejected = rejects {base = base // {outputName = "other";};};
    outPathRejected = rejects {base = base // {outPath = "/nix/store/other";};};
    drvPathRejected = rejects {base = base // {drvPath = "/nix/store/other.drv";};};
    suppliedBuildRejected = rejects {build = mkDrv "provided" {};};
    missingCraneRejected = rejects {pkgs = pkgs // {craneLib = null;};};
    derivedSourceRejected = rejects {src = mkDrv "source" {};};
    missingMemberRejected = rejects {projectDir = "members/absent";};
    extraDirsRejected = rejects {deps = ["members/library-a"];};
    escapeRejected = rejects {deps = ["../outside"];};
    missingDepDirRejected = rejects {internalDeps = [internal "members/absent"];};
    missingDepMetadataRejected = rejects {internalDeps = [mkDrv "dep" {}];};
    invalidDepRejected = rejects {internalDeps = [null];};
    precedenceWithoutLayers =
      (package {
        src = chainContext.src;
        base = chainBase;
        internalDeps = [(internal "members/library-a") (internal "members/library-a")];
      }).passthru.memberLayer.cargoArtifacts.drvPath
      == chainBase.drvPath;
    rollbackStillExplicit =
      (package {
        inherit base;
        useWorkspaceDeps = false;
      }).passthru.memberLayer.cargoArtifacts.drvPath
      == base.drvPath;
    compilerMismatchRejected = rejects {
      toolchain = {
        provider = "resolved";
        derivation = mkDrv "other-tools" {};
      };
    };
    libraryMismatchRejected = rejects {pkgs = pkgs // {craneLib = library "different-scripts";};};
    sourceOverrideRejected = rejects {buildAttrs.src = fixture;};
    vendorOverrideRejected = rejects {cargoVendorDir = mkDrv "vendor-override" {};};
    lockOverrideRejected = rejects {cargoLock.lockFileContents = builtins.readFile (fixture + "/Cargo.lock");};
    flagsRejected = rejects {cargoBuildArgs = ["--locked" "-p" "application" "--features" "other"];};
    orderedFlagsRejected = rejects {cargoBuildArgs = ["-p" "application" "--locked"];};
    checkFlagsRejected = rejects {checkCargoArgs = ["--all-targets"];};
    lintFlagsRejected = rejects {checkLintArgs = ["--" "--cfg" "different"];};
    crossContextRejected = rejects {pkgs = pkgs // {stdenv = pkgs.stdenv // {hostPlatform.system = "aarch64-linux";};};};
    unsupportedPlannerShapeRejected = rejects {src = ./fixtures/rust-closures/config;};
    testFlagsRejected = rejects {testCargoArgs = ["--release"];};
    envRejected = rejects {checkEnv.RUSTFLAGS = "-C opt-level=1";};
    nativeRejected = rejects {nativeCheckInputs = [pkgs.cargo];};
    nativeBuildRejected = rejects {buildAttrs.nativeBuildInputs = [pkgs.cargo];};
    functionStdenvRejected = rejects {buildAttrs.stdenv = p: p.stdenv;};
    hookRejected = rejects {prePatch = "touch unexpected";};
    profileRejected = rejects {buildAttrs.CARGO_PROFILE = "dev";};
    defaultCustomizationStillAccepted =
      (package {
        useWorkspaceDeps = false;
        buildAttrs.nativeBuildInputs = [pkgs.cargo];
      }).nativeBuildInputs
      == [pkgs.cargo];
    constructorIncompleteClosureRejected = fails (helper.mkClosureBase (chainContext // {deps = [];})).drvPath;
    constructorMissingFullLockRejected =
      fails
      (helper.mkClosureBase (context
        // {
          src = ./fixtures/rust-closures/regular;
          projectDir = "nested/a";
          deps = ["b"];
        })).drvPath;
    constructorMissingCrane = fails (helper.mkClosureBase (context // {pkgs = pkgs // {craneLib = null;};})).drvPath;
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert builtins.length (builtins.attrNames assertions) == 104;
  assert failed == [] || throw "rust-base failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
    # Evaluate --raw, then run with bash and an existing user-owned scratch dir.
    # This executes only GNU coreutils on tiny files, never Cargo/Nix builds.
    sourceScriptRegression =
      ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        unchained_projection() {
          ${scriptUnchained.src.buildCommand}
        }
        chained_projection() {
          ${scriptChained.src.buildCommand}
        }
      ''
      + builtins.readFile ./fixtures/rust-bases/read-only-root.sh
      + ''
        main "$@" ${scriptExpectedRoot}
      '';
  }
