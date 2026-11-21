# Pure file evaluation: nix eval --offline --option allow-import-from-derivation
# false --json --file ab/core/packaging/rust/tests/toolchain.nix
let
  mkDrv = name: attrs:
    attrs
    // {
      type = "derivation";
      outPath = "/nix/store/00000000000000000000000000000000-${name}";
      overrideAttrs = f: mkDrv name (attrs // f attrs);
    };
  toolA = mkDrv "rust-a" {};
  toolB = mkDrv "rust-b" {};
  fenixClippy = mkDrv "fenix-clippy" {};
  fenixRustfmt = mkDrv "fenix-rustfmt" {};
  mkLibrary = label: let
    build = kind: attrs: mkDrv "${label}-${kind}" (attrs // {library = label;});
  in {
    library = label;
    overrideToolchain = tool: mkLibrary tool.outPath;
    buildDepsOnly = build "deps";
    buildPackage = build "package";
    mkCargoDerivation = build "join";
    cargoBuild = build "member";
    cargoFmt = build "fmt";
    cargoClippy = build "clippy";
    cargoTest = build "test";
    mkDummySrc = build "dummy";
    vendorCargoDeps = build "vendor";
  };
  baseLibrary = mkLibrary "default";
  fakePkgs = {
    stdenv = {
      buildPlatform.system = "x86_64-linux";
      hostPlatform.system = "x86_64-linux";
    };
    craneLib = baseLibrary;
    cargo = mkDrv "cargo-default" {};
    rustc = mkDrv "rustc-default" {};
    clippy = mkDrv "clippy-default" {};
    rustfmt = mkDrv "rustfmt-default" {};
    rust-analyzer = mkDrv "rust-analyzer" {};
    git = mkDrv "git" {};
    binaryen = mkDrv "binaryen" {};
    llvmPackages.lld = mkDrv "lld" {};
    trunk = mkDrv "trunk" {};
    wasm-bindgen-cli_0_2_114 = mkDrv "wasm-bindgen" {};
    symlinkJoin = attrs: mkDrv "bundle" attrs;
    runCommand = name: attrs: script: mkDrv name (attrs // {inherit script;});
    runCommandLocal = name: attrs: script: mkDrv name (attrs // {inherit script;});
    writeShellApplication = attrs: mkDrv attrs.name attrs;
    mkShell = attrs: mkDrv "shell" attrs;
    rustPlatform.buildRustPackage = attrs: mkDrv "fallback" attrs;
    nix-gitignore.gitignoreFilterPure = _: _: _: _: _: true;
    extend = overlay: fakePkgs // overlay fakePkgs fakePkgs;
    lib = {
      cleanSourceWith = import ./mock-clean-source.nix;
      optional = condition: value:
        if condition
        then [value]
        else [];
      optionals = condition: values:
        if condition
        then values
        else [];
      unique = values:
        builtins.foldl' (acc: value:
          if builtins.elem value acc
          then acc
          else acc ++ [value]) []
        values;
    };
  };
  module = import ../toolchain.nix;
  resolver = module {pkgs = fakePkgs;};
  contract = {
    provider = "resolved";
    pkg = toolA;
  };
  otherContract = {
    provider = "resolved";
    pkg = toolB;
  };
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  pinnedCrane = {
    mkLib = packages:
      if packages.cargo.outPath == fakePkgs.cargo.outPath
      then baseLibrary
      else throw "mkLib got the wrong package set";
  };
  withProviders = module {
    pkgs = fakePkgs;
    inputs = {
      crane = pinnedCrane;
      fenix.packages.x86_64-linux = {
        stable = {
          minimalToolchain = toolB;
          defaultToolchain = toolA;
          completeToolchain = toolB;
          clippy = fenixClippy;
          rustfmt = fenixRustfmt;
        };
        combine = components: mkDrv "fenix-combined" {inherit components;};
        fromToolchainFile = args: mkDrv "fenix-file" args;
      };
      rust-overlay.overlays.default = _final: _prev: {
        rust-bin.fromRustupToolchainFile = file: mkDrv "oxalica-file" {inherit file;};
      };
    };
  };
  # Static path fixtures are evaluator-visible with IFD disabled. All build,
  # dummy-source and vendor operations below are mocks, never real compilation.
  fixtureRoot = ./fixtures/workspace;
  rootCargo = fixtureRoot + "/Cargo.toml";
  toolchainFile = rootCargo; # Valid TOML, with no toolchain profile.
  # toFile creates an already-realized evaluator fixture, not a derivation.
  # Drop only its string context to construct the Nix path required by the API.
  minimalFile = components:
    /.
    + builtins.unsafeDiscardStringContext (builtins.toFile "rust-toolchain-minimal.toml" ''
      [toolchain]
      channel = "1.95.0"
      profile = "minimal"
      components = ${builtins.toJSON components}
    '');
  legacyToolchainFile =
    /.
    + builtins.unsafeDiscardStringContext (builtins.toFile "rust-toolchain" "1.95.0\n");
  abiCrossPkgs =
    fakePkgs
    // {
      stdenv = {
        buildPlatform = {
          system = "x86_64-linux";
          config = "x86_64-unknown-linux-gnu";
        };
        hostPlatform = {
          system = "x86_64-linux";
          config = "x86_64-unknown-linux-musl";
        };
      };
    };
  foreignNativePkgs =
    fakePkgs
    // {
      stdenv = {
        buildPlatform = {
          system = "aarch64-linux";
          config = "aarch64-unknown-linux-gnu";
        };
        hostPlatform = {
          system = "aarch64-linux";
          config = "aarch64-unknown-linux-gnu";
        };
      };
    };
  overriddenLibrary =
    baseLibrary
    // {
      cargo = toolB;
      rustc = toolB;
      clippy = toolB;
      rustfmt = toolB;
    };
  overriddenPkgs = fakePkgs // {craneLib = overriddenLibrary;};
  lateOverlay = withProviders.overlay overriddenPkgs fakePkgs;
  crossSelectorLibrary = baseLibrary // {stdenvSelector = _: abiCrossPkgs.stdenv;};
  crossResolver = module {
    pkgs = fakePkgs // {stdenv = fakePkgs.stdenv // {hostPlatform.system = "aarch64-linux";};};
  };
  overlay = withProviders.overlay fakePkgs fakePkgs;
  selectedPkgs = fakePkgs // overlay;
  helper = import ../../pkg-helper.nix {
    projectRoot = ./.;
    treefmtConfig = null;
  };
  member = args:
    helper.mkRustDerivation ({
        pkgs = selectedPkgs;
        src = fixtureRoot;
        projectDir = "members/application";
        pname = "application";
      }
      // args);
  # Keep contract metadata out of the build arguments.
  package = helper.mkRustDerivation {
    pkgs = selectedPkgs;
    src = fixtureRoot;
    projectDir = "members/application";
    pname = "application";
    toolchain = contract;
    enableDevShell = true;
  };
  defaultPackage = member {};
  depA = helper.mkRustDerivation {
    pkgs = selectedPkgs;
    src = fixtureRoot;
    projectDir = "members/library-a";
    pname = "library-a";
    toolchain = contract;
  };
  depB = helper.mkRustDerivation {
    pkgs = selectedPkgs;
    src = fixtureRoot;
    projectDir = "members/library-b";
    pname = "library-b";
    toolchain = contract;
  };
  joined = member {
    toolchain = contract;
    internalDeps = [depA depB];
  };
  mismatched = member {
    toolchain = otherContract;
    internalDeps = [depA];
  };
  missingIdentity = member {
    toolchain = contract;
    internalDeps = [(mkDrv "unmarked-dep" {passthru = builtins.removeAttrs depA.passthru ["rustToolchainId"];})];
  };
  sourceOnlyDep = member {
    toolchain = contract;
    internalDeps = [(mkDrv "source-only-dep" {passthru.projectDir = "members/library-a";})];
  };
  trunkPackage = helper.mkTrunkProject {
    pkgs = selectedPkgs;
    src = fixtureRoot;
    pname = "trunk-test";
    toolchain = contract;
  };
  isolated = args:
    helper.mkCargoWorkspacePackage ({
        pkgs = selectedPkgs;
        src = fixtureRoot;
        pname = "isolated-test";
        toolchain = contract;
      }
      // args);
  opaqueBuild = mkDrv "opaque" {};
  foreignOpaqueBuild = mkDrv "opaque-foreign" {passthru.rustToolchainId = "producer-owned";};
  suppliedOpaque = member {build = opaqueBuild;};
  suppliedForeignOpaque = member {build = foreignOpaqueBuild;};
  suppliedMatchingLayer = member {
    build = depA;
    toolchain = contract;
  };
  suppliedMismatchedLayer = member {
    build = depA;
    toolchain = otherContract;
  };
  suppliedUnmarkedLayer = member {
    build = mkDrv "supplied-unmarked" {passthru = builtins.removeAttrs defaultPackage.passthru ["rustToolchainId"];};
  };
  certifiedOpaque = mkDrv "certified-opaque" {passthru.rustToolchainId = (resolver.toolchainFor contract).id;};
  isolatedDefault = helper.mkCargoWorkspacePackage {
    pkgs = selectedPkgs;
    src = fixtureRoot;
    pname = "isolated-test";
    toolchain = {};
  };
  fallbackPackage = helper.mkRustDerivation {
    pkgs = builtins.removeAttrs fakePkgs ["craneLib"];
    src = fixtureRoot;
    pname = "fallback-test";
  };
  gitLockArgs = {
    pkgs = fakePkgs;
    src = ./fixtures/git-lock;
    pname = "git-lock-fixture";
  };
  filteredGitLockPackage =
    helper.mkRustDerivation (gitLockArgs
      // {pkgs = builtins.removeAttrs fakePkgs ["craneLib"];});
  filteredCraneGitLock = helper.mkRustDerivation gitLockArgs;
  filteredIsolatedGitLock = helper.mkCargoWorkspacePackage gitLockArgs;
  filteredTrunkGitLock = helper.mkTrunkProject gitLockArgs;
  originalGitLock = builtins.readFile (gitLockArgs.src + "/Cargo.lock");
  explicitGitLock =
    helper.mkRustDerivation (gitLockArgs
      // {cargoLock.lockFileContents = originalGitLock;});
  filteredGitLock = filteredGitLockPackage.cargoLock.lockFileContents;
  results = {
    unboundResolverFailsClearly = fails ((module {}).toolchainFor null);
    defaultUnchanged = (resolver.toolchainFor null).build.crane == baseLibrary && (resolver.toolchainFor {}).build.crane == baseLibrary;
    defaultDoesNotRequireProviders = !(withProviders.toolchainFor null).custom;
    unusedProvidersStayLazy =
      ((module {
          pkgs = fakePkgs;
          inputs = {
            fenix = throw "unused fenix forced";
            rust-overlay = throw "unused oxalica forced";
            rust-nixpkgs = throw "unused pinned nixpkgs forced";
          };
        }).toolchainFor
        null).build.crane
      == baseLibrary;
    alternateNixpkgs =
      (resolver.toolchainFor {
        provider = "nixpkgs-rustc";
        pkgs = fakePkgs // {rustc = toolB;};
      }).pkg.paths
      == [toolB fakePkgs.cargo fakePkgs.clippy fakePkgs.rustfmt];
    selectedOverride = (withProviders.toolchainFor contract).build.crane.library == toolA.outPath;
    oneCoherentContract = let
      selected = withProviders.toolchainFor contract;
    in
      selected.build.crane.library
      == selected.pkg.outPath
      && selected.build.pkgs.rustc == selected.tools.rustc;
    lateOverlayLibraryHonored = (lateOverlay.toolchains.rust null).build.crane == overriddenLibrary;
    lateOverlayToolsHonored = (lateOverlay.toolchains.rust null).tools.cargo == toolB;
    overriddenDefaultOperationsMatch = let
      selected = (module {pkgs = overriddenPkgs;}).toolchainFor null;
    in
      selected.tools.rustc == toolB && selected.tools.clippy == toolB && selected.id == (lateOverlay.toolchains.rust null).id;
    identicalEffectiveCompilerIdentity = ((module {pkgs = overriddenPkgs;}).toolchainFor null).id == (resolver.toolchainFor otherContract).id;
    rejectsEffectiveCraneCrossSelector = fails ((module {pkgs = fakePkgs // {craneLib = crossSelectorLibrary;};}).toolchainFor contract);
    rejectsResolvedForeignNativeTool = fails (resolver.toolchainFor {
      provider = "resolved";
      pkg = toolA // {system = "aarch64-linux";};
    });
    rejectsCrossBuildStdenv = fails ((resolver.toolchainFor contract).build.validate {stdenv = abiCrossPkgs.stdenv;});
    acceptsNativeBuildStdenv = (resolver.toolchainFor contract).build.validate {stdenv = fakePkgs.stdenv;};
    preservesDefaultCrossBuildStdenv = (resolver.toolchainFor null).build.validate {stdenv = abiCrossPkgs.stdenv;};
    rejectsRUSTCEnvCertification = fails (member {buildAttrs.env.RUSTC = "compiler-b";}).passthru.rustToolchainId;
    rejectsRUSTCAttributeCertification = fails (member {RUSTC = "compiler-b";}).passthru.rustToolchainId;
    rejectsWrapperEnvCertification = fails (member {buildAttrs.env.RUSTC_WRAPPER = "wrapper";}).outPath;
    rejectsCompilerCheckEnv = fails (member {checkEnv.RUSTC = "compiler-b";}).outPath;
    rejectsCustomCrossBuildOverride =
      fails
      (member {
        toolchain = contract;
        buildAttrs.stdenv = abiCrossPkgs.stdenv;
      }).outPath;
    rejectsTrunkCompilerOverride =
      fails
      (helper.mkTrunkProject {
        pkgs = selectedPkgs;
        src = fixtureRoot;
        pname = "trunk-override";
        toolchain = contract;
        buildAttrs.env.RUSTC = "compiler-b";
      }).outPath;
    customToolsWithoutCraneForSuppliedBuild = ((module {pkgs = builtins.removeAttrs fakePkgs ["craneLib"];}).toolchainFor contract).tools.rustc == toolA;
    defaultToolsUnchanged = (resolver.toolchainFor null).tools.cargo == fakePkgs.cargo;
    selectedTools = (resolver.toolchainFor contract).tools.clippy == toolA;
    detectsPreOverriddenLibrary =
      (module {
        pkgs =
          fakePkgs
          // {
            craneLib =
              baseLibrary
              // {
                rustc = toolB;
                cargo = toolB;
              };
          };
      }).toolchainFor
      null
      != resolver.toolchainFor null;
    fenixPinnedProfile = (withProviders.toolchainFor {provider = "fenix";}).pkg == toolA;
    fenixMinimalIncludesOperationTools =
      (withProviders.toolchainFor {
        provider = "fenix";
        profile = "minimal";
      }).pkg.components
      == [toolB fenixClippy fenixRustfmt];
    rejectsMinimalFileWithoutTools =
      fails
      (withProviders.toolchainFor {
        provider = "fenix";
        toolchainFile = minimalFile [];
        sha256 = "hash";
      }).id;
    rejectsMinimalFileMissingClippy =
      fails
      (withProviders.toolchainFor {
        provider = "fenix";
        toolchainFile = minimalFile ["rustfmt"];
        sha256 = "hash";
      }).id;
    rejectsMinimalFileMissingRustfmt =
      fails
      (withProviders.toolchainFor {
        provider = "oxalica";
        toolchainFile = minimalFile ["clippy"];
      }).id;
    minimalFileWithBothTools =
      (withProviders.toolchainFor {
        provider = "fenix";
        toolchainFile = minimalFile ["clippy" "rustfmt"];
        sha256 = "hash";
      }).pkg.sha256
      == "hash";
    acceptsLegacyOxalicaToolchainFile =
      (withProviders.toolchainFor {
        provider = "oxalica";
        toolchainFile = legacyToolchainFile;
      }).pkg.file
      == legacyToolchainFile;
    rejectsSameSystemABICross = fails ((module {pkgs = abiCrossPkgs;}).toolchainFor contract).build.crane;
    rejectsAlternateABICross = fails (resolver.toolchainFor {
      provider = "nixpkgs-rustc";
      pkgs = abiCrossPkgs;
    });
    rejectsForeignNativeTools = fails (resolver.toolchainFor {
      provider = "nixpkgs-rustc";
      pkgs = foreignNativePkgs;
    });
    rejectsCustomCrossToolchain = fails (crossResolver.toolchainFor contract);
    preservesDefaultCrossToolchain = (crossResolver.toolchainFor null).build.crane == baseLibrary;
    fenixCompleteProfile =
      (withProviders.toolchainFor {
        provider = "fenix";
        profile = "complete";
      }).pkg
      == toolB;
    rejectsConflictingFenixFile = fails (withProviders.toolchainFor {
      provider = "fenix";
      inherit toolchainFile;
      profile = "complete";
      sha256 = "hash";
    });
    rejectsIgnoredFenixHash = fails (withProviders.toolchainFor {
      provider = "fenix";
      sha256 = "hash";
    });
    rejectsUnknownFenixProfile = fails (withProviders.toolchainFor {
      provider = "fenix";
      profile = "typo";
    });
    rejectsIgnoredTargets = fails (withProviders.toolchainFor {
      provider = "fenix";
      targets = ["wasm32-unknown-unknown"];
    });
    rejectsIgnoredComponents = fails (withProviders.toolchainFor {
      provider = "fenix";
      components = ["rust-src"];
    });
    fenixFileHash =
      (withProviders.toolchainFor {
        provider = "fenix";
        inherit toolchainFile;
        sha256 = "fake-fixed-hash";
      }).pkg.sha256
      == "fake-fixed-hash";
    oxalicaFileAdapter =
      (withProviders.toolchainFor {
        provider = "oxalica";
        inherit toolchainFile;
      }).pkg.file
      == toolchainFile;
    missingFenix = fails (resolver.toolchainFor {provider = "fenix";}).id;
    missingOxalica = fails (resolver.toolchainFor {
      provider = "oxalica";
      inherit toolchainFile;
    });
    missingPinnedNixpkgs = fails (resolver.toolchainFor {provider = "pinned-nixpkgs";}).pkg;
    missingManifestHash =
      fails
      (withProviders.toolchainFor {
        provider = "fenix";
        inherit toolchainFile;
      }).pkg.sha256;
    rejectsIFDFile = fails (withProviders.toolchainFor {
      provider = "oxalica";
      toolchainFile = toolA;
    });
    rejectsMutableRustup = fails (resolver.toolchainFor {provider = "rustup";}).id;
    rejectsResolvedRustup = fails (resolver.toolchainFor {
      provider = "resolved";
      pkg = mkDrv "rustup" {pname = "rustup";};
    });
    rejectsUnknown = fails (resolver.toolchainFor {provider = "unknown";}).id;
    rejectsNonDerivation = fails (resolver.toolchainFor {
      provider = "resolved";
      pkg = "/mutable/rustup";
    });
    rejectsIgnoredContractFields = fails (resolver.toolchainFor {channel = "nightly";}).id;
    requiresCraneForCustom = fails ((module {pkgs = builtins.removeAttrs fakePkgs ["craneLib"];}).toolchainFor contract).build.crane;
    providerSwappable =
      ((module {
        pkgs = fakePkgs;
        providers.fenix = _spec: toolB;
      }).toolchainFor {provider = "fenix";}).build.crane.library
      == toolB.outPath;
    rootAndFallbackSeam = overlay.craneLib.library == "default" && (overlay.toolchains.rust contract).build.crane.library == toolA.outPath;
    defaultHelperLibrary = defaultPackage.library == "default";
    selectedHelperLibrary = package.library == toolA.outPath;
    selectedSharedBase = package.passthru.sharedDepsBase.library == toolA.outPath;
    selectedDummy = package.passthru.sharedDepsBase.dummySrc.library == toolA.outPath;
    selectedVendor = package.cargoVendorDir.library == toolA.outPath;
    selectedMemberLayer = package.passthru.memberLayer.library == toolA.outPath;
    selectedChecks = builtins.all (name: package.passthru.checks.${name}.library == toolA.outPath) ["fmt" "lint" "test"];
    selectedJoin = joined.passthru.memberLayer.cargoArtifacts.library == toolA.outPath && joined.passthru.memberLayer.cargoArtifacts.pname == "application-cargo-artifacts";
    rejectsMismatchedArtifacts = fails mismatched.passthru.memberLayer.cargoArtifacts;
    rejectsUnmarkedArtifacts = fails missingIdentity.passthru.memberLayer.cargoArtifacts;
    sourceOnlyDependencyAllowed = sourceOnlyDep.passthru.memberLayer.cargoArtifacts.library == toolA.outPath;
    contractDoesNotLeak = !(package ? toolchain);
    selectedOperations = builtins.head package.passthru.pkgOps.apps.fmt.runtimeInputs == toolA;
    selectedShell = builtins.head package.passthru.devShell.packages == toolA;
    selectedTrunk = trunkPackage.library == toolA.outPath && trunkPackage.cargoArtifacts.library == toolA.outPath;
    rejectsCustomIsolatedWorkspace = fails (isolated {}).outPath;
    # Negative tests prove these arguments cannot silently enter a Crane build
    # whose commands ignore rustPlatform flags. No mock attribute forwarding is
    # treated as evidence that Cargo would run the requested build/test scopes.
    rejectsCustomIsolatedDistinctBuildTestArgs =
      fails
      (isolated {
        cargoBuildArgs = ["--locked" "-p" "build-member" "--features" "build-feature"];
        testCargoArgs = ["--locked" "-p" "test-member" "--features" "test-feature"];
      }).outPath;
    rejectsCustomIsolatedFlagOverrides =
      fails
      (isolated {
        buildAttrs = {
          cargoBuildFlags = ["-p" "build-member"];
          cargoTestFlags = ["-p" "test-member" "--no-default-features"];
        };
      }).outPath;
    preservesOpaqueProducerIdentity = suppliedForeignOpaque.passthru.rustToolchainId == "producer-owned";
    doesNotCertifyOpaqueSuppliedBuild = !(suppliedOpaque.passthru ? rustToolchainId) && !(suppliedOpaque.passthru ? memberLayer);
    rejectsUnverifiableCustomSuppliedBuild =
      fails
      (member {
        build = opaqueBuild;
        toolchain = contract;
      }).outPath;
    rejectsCustomSuppliedForeignIdentity =
      fails
      (member {
        build = foreignOpaqueBuild;
        toolchain = contract;
      }).outPath;
    acceptsCertifiedCustomSuppliedBuild =
      (member {
        build = certifiedOpaque;
        toolchain = contract;
      }).passthru.rustToolchainId
      == certifiedOpaque.passthru.rustToolchainId;
    rejectsSuppliedMismatchedLayer = fails suppliedMismatchedLayer.outPath;
    cannotReadRelabeledSuppliedIdentity = fails suppliedMismatchedLayer.passthru.rustToolchainId;
    rejectsSuppliedLayerWithoutProducerIdentity = fails suppliedUnmarkedLayer.outPath;
    rejectsSuppliedForeignLayerUnderDefault = fails (member {build = depA;}).outPath;
    preservesMatchingSuppliedLayer = suppliedMatchingLayer.passthru.memberLayer.outPath == depA.passthru.memberLayer.outPath && suppliedMatchingLayer.passthru.rustToolchainId == depA.passthru.rustToolchainId;
    defaultIsolatedWorkspaceUnchanged = isolatedDefault.outPath == "/nix/store/00000000000000000000000000000000-fallback";
    rejectsProjectDirForIsolatedWorkspace =
      fails
      (isolated {
        toolchain = {};
        projectDir = "members/agent";
      }).outPath;
    rejectsCustomTrunkFallback =
      fails
      (helper.mkTrunkProject {
        pkgs = selectedPkgs;
        src = fixtureRoot;
        pname = "fallback-trunk";
        toolchain = contract;
        buildAttrs.cargoDeps = toolB;
      }).outPath;
    defaultWithoutCrane = fallbackPackage.outPath == "/nix/store/00000000000000000000000000000000-fallback";
    noPolicyPreservesOriginalLock = fallbackPackage.cargoLock.lockFileContents == builtins.readFile (fixtureRoot + "/Cargo.lock");
    filteredFallbackInstallsVendorLock = (filteredGitLockPackage.rustPlatformLockfile or null) == filteredGitLock;
    filteredCranePackageAndVendorAgree = filteredCraneGitLock.cargoLockContents == filteredGitLock && filteredCraneGitLock.cargoVendorDir.cargoLockContents == filteredGitLock;
    filteredIsolatedSourceAndVendorAgree = filteredIsolatedGitLock.cargoLock.lockFileContents == filteredGitLock && (filteredIsolatedGitLock.rustPlatformLockfile or null) == filteredGitLock;
    filteredTrunkPackageAndVendorAgree = filteredTrunkGitLock.cargoLockContents == filteredGitLock && filteredTrunkGitLock.cargoVendorDir.cargoLockContents == filteredGitLock;
    explicitLockOverridesSidecar = explicitGitLock.cargoLockContents == originalGitLock && explicitGitLock.cargoVendorDir.cargoLockContents == originalGitLock;
    privateGitSourceIsReplacedForNix = let
      contents = filteredGitLock;
      source = "git+https://example.invalid/private?rev=012345#012345";
    in
      builtins.replaceStrings [source] [""] contents
      == contents
      && builtins.match ".*private-kernel.*" (builtins.replaceStrings ["\n"] [" "] contents) != null;
  };
in
  assert builtins.all (name:
    if results.${name}
    then true
    else throw "rust-toolchain test failed: ${name}") (builtins.attrNames results); results
