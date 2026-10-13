# Constructor/consumer integration, not tests of the private pure projector.
# Optional real pkgs exercise the same synthetic manager/agent/bridge shapes.
{
  pkgs ? null,
  toolchain ? null,
  snapshot ? null,
}: let
  helper = import ../pkg-helper.nix;
  previous =
    if snapshot == null
    then helper
    else import snapshot;
  mkDrv = name: attrs: let
    hash = builtins.substring 0 32 (builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs attrs ["passthru"])));
    path = "/nix/store/${hash}-${name}";
  in
    attrs
    // {
      type = "derivation";
      outPath = builtins.appendContext path (builtins.getContext "${./fixtures/rust-composition}");
      drvPath = "${path}.drv";
      outputName = "out";
      overrideAttrs = f: mkDrv name (attrs // f attrs);
    };
  library = label: let
    build = name: attrs: mkDrv name (attrs // {library = label;});
  in {
    overrideToolchain = tool: library tool.outPath;
    cleanCargoToml = {cargoToml}: builtins.fromTOML (builtins.readFile cargoToml);
    writeTOML = name: data: build name {inherit data;};
    mkDummySrc = build "dummy";
    vendorCargoDeps = build "vendor";
    buildDepsOnly = attrs:
      build "deps" ((builtins.removeAttrs attrs ["dummySrc"])
        // {
          src = attrs.dummySrc;
          cargoArtifacts = null;
          env = (attrs.env or {}) // {CRANE_BUILD_DEPS_ONLY = 1;};
          doInstallCargoArtifacts = true;
        });
    buildPackage = build "package";
    cargoBuild = build "member";
    cargoFmt = build "fmt";
    cargoClippy = build "lint";
    cargoTest = build "test";
    mkCargoDerivation = build "chained";
  };
  mocks = {
    craneLib = library "default";
    stdenv = {
      buildPlatform.system = "x86_64-linux";
      hostPlatform.system = "x86_64-linux";
    };
    cargo = mkDrv "cargo" {};
    rustc = mkDrv "rustc" {};
    clippy = mkDrv "clippy" {};
    rustfmt = mkDrv "rustfmt" {};
    pkg-config = mkDrv "pkg-config" {};
    openssl = mkDrv "openssl" {};
    protobuf = mkDrv "protobuf" {};
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
  packages =
    if pkgs == null
    then mocks
    else pkgs;
  context = {
    pkgs = packages;
    src = ./fixtures/rust-composition;
    inherit toolchain;
  };
  member = "members/application";
  dirs = ["members/branch" "members/leaf" "members/middle"];
  args = {
    projectDir = member;
    projectPath = member;
    pname = "application";
    deps = dirs;
  };
  ctor = h: record: parent:
    h.mkClosureBase (context
      // {
        projectDir = member;
        deps = dirs;
        buildAttrs = record;
        inherit parent;
      });
  compose = record:
    helper.mkRustComposition (context
      // {
        baseMode = "member";
        buildAttrs = record;
      });
  consumer = extra: helper.mkRustDerivation (context // args // extra);
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  inputA = packages.pkg-config;
  inputB = packages.protobuf;
  manager = {
    nativeBuildInputs = [inputA inputA];
    buildInputs = [packages.openssl];
    env = {
      OPENSSL_DIR = packages.openssl;
      PKG_CONFIG_PATH = "${packages.openssl}/lib/pkgconfig";
    };
  };
  agent =
    manager
    // {
      env = {
        PROTOC = "${inputB}/bin/protoc";
        PROTOC_INCLUDE = ./fixtures/rust-composition;
      };
    };
  bridge =
    manager
    // {
      env = {
        LIBCLANG_PATH = "${packages.openssl}/lib";
        OPENSSL_STATIC = "1";
      };
    };
  record =
    manager
    // {
      nativeCheckInputs = [inputB inputA];
      lintNativeBuildInputs = [inputA];
    };
  native = [inputA inputA inputB inputA inputA];
  factory = compose record;
  base = factory.baseFor member;
  branch = base.passthru.rustClosureBaseParent;
  leaf = branch.passthru.rustClosureBaseParent;
  package = factory.mkRustDerivation args;
  checks = package.passthru.checks;
  layer = package.passthru.memberLayer;
  stages = [base branch leaf layer package checks.fmt checks.lint checks.test];
  prefix = expected: actual:
    builtins.length actual
    >= builtins.length expected
    && builtins.genList (i: builtins.elemAt actual i) (builtins.length expected) == expected;
  envAt = drv: key: (drv.env or {}).${key} or drv.${key};
  marker = drv: toString (envAt drv "CRANE_BUILD_DEPS_ONLY") == "1";
  hook = ''
    chmod -R u+w "$out"
    echo native-packaging-only > "$out/packaging-marker"
  '';
  packaged = factory.mkRustDerivation (args
    // {
      buildAttrs = {
        postInstall = hook;
        doCheck = false;
        meta.description = "final native package";
      };
    });
  emptyBase = ctor helper {} null;
  emptyOldBase = previous.mkClosureBase (context
    // {
      projectDir = member;
      deps = dirs;
    });
  oldFactory = previous.mkRustComposition (context // {baseMode = "member";});
  oldBase = oldFactory.baseFor member;
  directZero = consumer {base = emptyBase;};
  previousZero = previous.mkRustDerivation (context // args // {base = emptyOldBase;});
  autoCall = factory.mkRustDerivation (args
    // {
      nativeCheckInputs = [inputB inputB];
      lintNativeBuildInputs = [inputB];
    });
  autoNative = [inputA inputA inputB inputB inputB inputA inputB inputA];
  swapped = factory.mkRustDerivation (args // {buildAttrs.env = {PROTOC = inputB;};});
  equivalent = compose {
    nativeBuildInputs = native;
    buildInputs = record.buildInputs;
    env = record.env;
  };
  swapParent = b: p:
    b.overrideAttrs (old: {
      passthru =
        old.passthru
        // {
          rustClosureBaseParent = p;
          rustClosureBaseRecipe = old.passthru.rustClosureBaseRecipe // {parent = p.passthru.rustClosureBaseRecipe;};
        };
    });
  rejectAncestor = p:
    fails
    (consumer {
      buildAttrs = record;
      base = swapParent base (swapParent branch p);
    }).drvPath;
  rejectMatching = extra:
    fails
    (consumer ({
        inherit base;
        buildAttrs = record;
      }
      // extra)).drvPath;
  invalidAttrs = value: rejectMatching {buildAttrs = record // value;};
  malicious = factory.mkRustDerivation (args // {buildAttrs.postInstall = ''mkdir -p "$out/target"; touch "$out/target.tar.zst" "$out/target.tar.zst.prev"'';});
  alternateTools =
    if pkgs == null
    then mkDrv "alternate-operation-tools" {}
    else
      packages.symlinkJoin {
        name = "alternate-operation-tools";
        paths = [packages.rustc packages.cargo packages.clippy packages.rustfmt];
      };
  alternateToolchain = {
    provider = "resolved";
    derivation = alternateTools;
  };
  alternateFactory = helper.mkRustComposition (context
    // {
      toolchain = alternateToolchain;
      baseMode = "member";
      buildAttrs = record;
    });
  alternateBase = alternateFactory.baseFor member;
  alternateAutomatic = factory.mkRustDerivation (args // {toolchain = alternateToolchain;});
  alternateExplicit = consumer {
    toolchain = alternateToolchain;
    buildAttrs = record;
    base = alternateBase;
  };
  literal = "$NATIVE_CONTEXT_LITERAL 'quoted' $(not-a-command) `not-a-command` \\ slash\nsecond line";
  literalPackage = (compose {env.OPENSSL_DIR = literal;}).mkRustDerivation (args // {checkEnv.OPENSSL_DIR = literal;});
  hasInfix = needle: text: builtins.length (builtins.split needle text) > 1;
  identities = drv: {
    final = drv.drvPath;
    member = drv.passthru.memberLayer.drvPath;
    fmt = drv.passthru.checks.fmt.drvPath;
    lint = drv.passthru.checks.lint.drvPath;
    test = drv.passthru.checks.test.drvPath;
  };
  assertions =
    {
      managerShape = (compose manager).mkRustDerivation args != null;
      agentShape = (compose agent).mkRustDerivation args != null;
      bridgeShape = (compose bridge).mkRustDerivation args != null;
      allStagesNativeOrderingDuplicates = builtins.all (drv: prefix native drv.nativeBuildInputs) stages;
      allStagesBuildInputs = builtins.all (drv: map (input: input.drvPath) drv.buildInputs == [packages.openssl.drvPath]) stages;
      allStagesEnv = builtins.all (drv: envAt drv "OPENSSL_DIR" == toString packages.openssl) stages;
      envContextPreserved = builtins.all (drv: builtins.hasContext (envAt drv "PKG_CONFIG_PATH")) stages;
      normalizedPathEnv = builtins.hasContext (envAt ((compose agent).baseFor member) "PROTOC_INCLUDE");
      producersMarkerPreserved = builtins.all marker [base branch leaf];
      rolesRemoved = builtins.all (drv: (drv.nativeCheckInputs or []) == [] && !(drv ? lintNativeBuildInputs)) stages;
      factoryConsumerCoherent = package.passthru.depsBase.drvPath == base.drvPath;
      finalInheritsLayer = package.cargoArtifacts.drvPath == layer.drvPath;
      checksInheritLayer = checks.lint.cargoArtifacts.drvPath == layer.drvPath && checks.test.cargoArtifacts.drvPath == layer.drvPath;
      contextualAncestors = branch.cargoArtifacts.drvPath == leaf.drvPath && leaf.cargoArtifacts == null;
      directConstructorCoherent = (ctor helper record branch).drvPath == base.drvPath;
      promotedEquivalentContext = (equivalent.baseFor member).drvPath == base.drvPath;
      sourceRecipeUnchanged = base.passthru.rustClosureBaseRecipe == oldBase.passthru.rustClosureBaseRecipe;
      noCompileCertificate = builtins.attrNames base.passthru.rustClosureBaseRecipe == ["parent" "projectDir" "sourceDirs" "version"];
      namedCallOrdering = prefix autoNative autoCall.nativeBuildInputs;
      namedCallContextualAncestors = prefix autoNative autoCall.passthru.depsBase.passthru.rustClosureBaseParent.nativeBuildInputs;
      namedCallDoesNotChangeBaseFor = base.drvPath == (factory.baseFor member).drvPath && autoCall.passthru.depsBase.drvPath != base.drvPath;
      envShallowReplacement = envAt swapped "PROTOC" == toString inputB && !(swapped ? OPENSSL_DIR) && !((swapped.env or {}) ? OPENSSL_DIR);
      envReplacementConsumerCoherent = envAt swapped.passthru.depsBase "PROTOC" == toString inputB;
      fmtOnlyExtra = let p = factory.mkRustDerivation (args // {fmtNativeBuildInputs = [inputB];}); in prefix (native ++ [inputB]) p.passthru.checks.fmt.nativeBuildInputs && p.passthru.memberLayer.drvPath == layer.drvPath;
      packagingOnlyFinal = hasInfix "native-packaging-only" packaged.postInstall && packaged.drvPath != package.drvPath;
      packagingDoesNotChangeLayer = packaged.passthru.memberLayer.drvPath == layer.drvPath;
      packagingDoesNotChangeBase = packaged.passthru.depsBase.drvPath == base.drvPath;
      packagingDoesNotChangeChecks = builtins.all (name: packaged.passthru.checks.${name}.drvPath == checks.${name}.drvPath) ["fmt" "lint" "test"];
      producerNeverPostInstall = builtins.all (drv: (drv.postInstall or "") == "") [base branch leaf layer checks.fmt checks.lint checks.test];
      stageMetadataAbsent = builtins.all (drv: !(drv.meta or {}) ? description) [base branch leaf layer checks.fmt checks.lint checks.test];
      finalMetadata = packaged.meta.description == "final native package";
      doCheckFinalOnly = !packaged.doCheck && base.doCheck && branch.doCheck && leaf.doCheck && checks.test.doCheck;
      packagingConstructorIgnored =
        (ctor helper (record
          // {
            postInstall = hook;
            doCheck = false;
            meta.description = "ignored";
          })
        branch).drvPath
        == base.drvPath;
      finalNoArtifactPublication = !package.doInstallCargoArtifacts && !packaged.doInstallCargoArtifacts;
      maliciousHookAcceptedOnMatchingContext = malicious.passthru.depsBase.drvPath == base.drvPath && malicious.passthru.memberLayer.drvPath == layer.drvPath;
      ownedGuardAllPaths = builtins.all (path: hasInfix path malicious.rustFinalOutputCheckPhase) ["[$]out/target" "[$]out/target.tar.zst" "[$]out/target.tar.zst.prev"];
      ownedGuardAfterHook = malicious.postPhases == ["rustFinalOutputCheckPhase"] && !hasInfix "for artifact" malicious.postInstall;
      guardOnlyOnExpandedFinal = !(directZero ? rustFinalOutputCheckPhase) && builtins.all (drv: !(drv ? rustFinalOutputCheckPhase)) [base branch leaf layer checks.fmt checks.lint checks.test];
      automaticActualToolchainMatchesExplicit = identities alternateAutomatic == identities alternateExplicit;
      automaticActualToolchainAncestors = alternateAutomatic.passthru.depsBase.passthru.rustClosureBaseParent.drvPath == alternateBase.passthru.rustClosureBaseParent.drvPath;
      automaticToolchainDoesNotChangeFactoryBase = (factory.baseFor member).drvPath == base.drvPath && alternateBase.drvPath != base.drvPath;
      automaticToolchainRecipeUnchanged = alternateAutomatic.passthru.depsBase.passthru.rustClosureBaseRecipe == base.passthru.rustClosureBaseRecipe;
      operationToolsAreActualSelection = builtins.all (name: toString alternateAutomatic.passthru.actualOperationTools.${name} == toString alternateTools) ["cargo" "rustc" "clippy" "rustfmt"];
      staleFactoryBaseRejectedWithActualToolchain = rejectMatching {toolchain = alternateToolchain;};
      resetFactoryToolchainToNull = identities (alternateFactory.mkRustDerivation (args // {toolchain = null;})) == identities package;
      localChecksShareProjectedEnv = builtins.all (name: package.passthru.pkgOps.checks.${name}.envScript == package.passthru.pkgOps.checks.test.envScript && hasInfix "OPENSSL_DIR" package.passthru.pkgOps.checks.${name}.envScript && hasInfix "PKG_CONFIG_PATH" package.passthru.pkgOps.checks.${name}.envScript) ["fmt" "lint" "test"];
      localRedundantEnvDoesNotShadow = (factory.mkRustDerivation (args // {checkEnv = manager.env;})).passthru.pkgOps.checks.test.envScript == package.passthru.pkgOps.checks.test.envScript;
      localConflictingEnvRejected = fails (factory.mkRustDerivation (args // {checkEnv.OPENSSL_DIR = "different";})).passthru.pkgOps.checks.test.envScript;
      localLiteralEnvIsQuoted = hasInfix "export OPENSSL_DIR='" literalPackage.passthru.pkgOps.checks.test.envScript;
      localEnvStringContextPreserved = builtins.hasContext package.passthru.pkgOps.checks.test.envScript;
      sourceAncestorMismatch = rejectAncestor (leaf.overrideAttrs (_: {src = context.src;}));
      vendorAncestorMismatch = rejectAncestor (leaf.overrideAttrs (_: {cargoVendorDir = inputB;}));
      compilerAncestorMismatch = rejectAncestor (leaf.overrideAttrs (old: {nativeBuildInputs = old.nativeBuildInputs ++ [packages.rustc];}));
      envAncestorMismatch = rejectAncestor (leaf.overrideAttrs (old: {env = (old.env or {}) // {OPENSSL_DIR = "different";};}));
      nativeAncestorMismatch = rejectAncestor (leaf.overrideAttrs (old: {nativeBuildInputs = [inputB] ++ old.nativeBuildInputs;}));
      noncontextualBaseRejected = rejectMatching {base = oldBase;};
      redundantCheckEnvAccepted = (factory.mkRustDerivation (args // {checkEnv = manager.env;})).drvPath == package.drvPath;
      redundantLiteralEnvNotReexported = let
        literal = "$NATIVE_CONTEXT_LITERAL";
        p = (compose {env.OPENSSL_DIR = literal;}).mkRustDerivation (args // {checkEnv.OPENSSL_DIR = literal;});
      in
        envAt p.passthru.checks.test "OPENSSL_DIR" == literal && !hasInfix "export" p.passthru.checks.test.preBuild;
      divergentCheckEnvRejected = rejectMatching {checkEnv.OPENSSL_DIR = "different";};
      unknownCheckEnvRejected = rejectMatching {checkEnv.HOME = "/tmp";};
      reservedCompilerBeforeDrop = invalidAttrs {RUSTC = packages.rustc;};
      reservedCompilerEnvBeforeDrop = invalidAttrs {env = manager.env // {RUSTC = packages.rustc;};};
      unknownEnvRejected = invalidAttrs {env = manager.env // {PATH = "/bin";};};
      cargoEnvRejected = invalidAttrs {env = manager.env // {CARGO_HOME = "/tmp/cargo";};};
      flagsEnvRejected = invalidAttrs {env = manager.env // {RUSTFLAGS = "-Copt-level=1";};};
      unknownEffectiveAttrBeforeDrop = rejectMatching {postBuild = "echo forbidden";};
      stdenvRejected = invalidAttrs {stdenv = p: p.stdenv;};
      prePatchRejected = rejectMatching {prePatch = "touch forbidden";};
      lockRejected = rejectMatching {cargoLock.lockFileContents = builtins.readFile (context.src + "/Cargo.lock");};
      flagsRejected = rejectMatching {cargoBuildArgs = ["--all-targets"];};
      artifactControlRejected = invalidAttrs {doInstallCargoArtifacts = true;};
      constructorReservedRejected = fails (ctor helper (record // {env.RUSTC = packages.rustc;}) branch).drvPath;
      constructorUnknownRejected = fails (ctor helper (record // {postBuild = "forbidden";}) branch).drvPath;
    }
    // (
      if snapshot == null
      then {}
      else {
        # Only label these prephase comparisons when a genuine snapshot is supplied.
        zeroV1ConstructorExact = emptyBase.drvPath == emptyOldBase.drvPath;
        zeroV1ConsumerExact = identities directZero == identities previousZero;
        zeroV2ConstructorExact = ((compose {}).baseFor member).drvPath == oldBase.drvPath;
        zeroV2ConsumerExact = identities ((compose {}).mkRustDerivation args) == identities (oldFactory.mkRustDerivation args);
        defaultNullExact = identities (consumer {base = null;}) == identities (previous.mkRustDerivation (context // args // {base = null;}));
        emptyProjectedConstructorExact =
          (ctor helper {
              env = {};
              nativeBuildInputs = [];
              doCheck = false;
            }
            null).drvPath
          == emptyOldBase.drvPath;
      }
    );
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-native-context failures: ${builtins.concatStringsSep ", " failed}"; {
    inherit assertions;
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }
