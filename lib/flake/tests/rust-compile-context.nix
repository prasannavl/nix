let
  projector = import ../rust-compile-context.nix;
  toolchain.validateBuildAttrs = attrs:
    if attrs ? RUSTC || (attrs.env or {}) ? RUSTC
    then throw "reserved compiler input"
    else true;
  a = {
    type = "derivation";
    outPath = builtins.toFile "native-context-a" "a";
  };
  b = {
    type = "derivation";
    outPath = builtins.toFile "native-context-b" "b";
  };
  project = record:
    projector.projectRecord {
      selectedToolchain = toolchain;
      inherit record;
    };
  consumer = args: buildArgs:
    projector.projectConsumer {
      selectedToolchain = toolchain;
      inherit args buildArgs;
    };
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  base = {
    nativeBuildInputs = [a b];
    nativeCheckInputs = [a];
    lintNativeBuildInputs = [b a];
    buildInputs = [b a b];
    env.OPENSSL_DIR = a;
  };
  result = project base;
  merged = consumer {
    nativeCheckInputs = [b];
    lintNativeBuildInputs = [a];
    buildAttrs = base;
  } {};
  assertions = {
    emptyExact = project {} == {};
    explicitEmptyExact =
      project {
        nativeBuildInputs = [];
        buildInputs = [];
        env = {};
      }
      == {};
    orderedNativeInputs = result.nativeBuildInputs == [a b a b a];
    orderedBuildInputs = result.buildInputs == [b a b];
    namedAppendOrder = merged.compileAttrs.nativeBuildInputs == [a b b a a b a];
    rolesRemoved = !(result ? nativeCheckInputs) && !(result ? lintNativeBuildInputs);
    derivedValueNormalized = result.env.OPENSSL_DIR == toString a;
    derivedContextPreserved = builtins.hasContext result.env.OPENSSL_DIR;
    pathContextPreserved = builtins.hasContext (project {env.PROTOC_INCLUDE = ./fixtures/rust-workspace;}).env.PROTOC_INCLUDE;
    stringContextPreserved = builtins.hasContext (project {env.PROTOC = "${a}/bin/protoc";}).env.PROTOC;
    packagingExcluded =
      project (base
        // {
          postInstall = "echo package";
          doCheck = false;
          meta.description = "package";
        })
      == result;
    packagingReturned =
      (consumer {
        buildAttrs = {
          postInstall = "echo package";
          doCheck = false;
        };
        meta.description = "outer";
      } {}).packagingAttrs
      == {
        postInstall = "echo package";
        doCheck = false;
        meta.description = "outer";
      };
    metadataPrecedence =
      (consumer {
        meta.description = "outer";
        buildAttrs.meta.description = "inner";
      } {}).packagingAttrs.meta.description
      == "inner";
    mergedNativePrecedence = (consumer {buildAttrs.nativeBuildInputs = [b];} {nativeBuildInputs = [a];}).compileAttrs.nativeBuildInputs == [b];
    mergedEnvironmentReplaces = (consumer {buildAttrs.env.OPENSSL_LIB_DIR = "inner";} {env.OPENSSL_DIR = "outer";}).compileAttrs.env == {OPENSSL_LIB_DIR = "inner";};
    redundantCheckEnv =
      (consumer {
        buildAttrs.env.OPENSSL_DIR = a;
        checkEnv.OPENSSL_DIR = toString a;
      } {}).compileAttrs.env.OPENSSL_DIR
      == toString a;
    unequalCheckEnvRejected = fails (consumer {
      buildAttrs.env.OPENSSL_DIR = "a";
      checkEnv.OPENSSL_DIR = "b";
    } {});
    checkOnlyEnvRejected = fails (consumer {checkEnv.OPENSSL_DIR = "b";} {});
    recordShapeRejected = fails (project []);
    nativeListTypeRejected = fails (project {nativeBuildInputs = "a";});
    nativeNonDerivationRejected = fails (project {nativeBuildInputs = ["a"];});
    nativeNullRejected = fails (project {nativeCheckInputs = [null];});
    nativeFunctionRejected = fails (project {buildInputs = [(_: a)];});
    doCheckTypeRejected = fails (project {doCheck = "true";});
    hookTypeRejected = fails (project {postInstall = false;});
    metadataTypeRejected = fails (project {meta = "metadata";});
    namedMetadataTypeRejected = fails (consumer {meta = "metadata";} {});
    stdenvCallbackRejected = fails (project {stdenv = _: throw "callback must not run";});
    unsupportedHookRejected = fails (consumer {buildAttrs.preBuild = "echo unsupported";} {});
    artifactControlRejected = fails (project {doInstallCargoArtifacts = true;});
    compilerReservationBeforeProjection = fails (consumer {buildAttrs.RUSTC = a;} {});
    topCompilerReservationBeforeProjection = fails (consumer {} {RUSTC = a;});
    envCompilerReservationRejected = fails (project {env.RUSTC = a;});
    unsupportedEnvironmentRejected = builtins.all (name: fails (project {env.${name} = "unsafe";})) ["CARGO_HOME" "CARGO_PROFILE" "CARGO_BUILD_TARGET" "RUSTFLAGS" "RUSTUP_HOME" "PATH" "HOME" "CC" "NIX_CFLAGS_COMPILE" "CRANE_BUILD_DEPS_ONLY" "BASH_ENV"];
    environmentValueTypesRejected = builtins.all (value: fails (project {env.OPENSSL_DIR = value;})) [null true 1 [] {} (_: "a")];
    environmentShapeRejected = fails (project {env = "not-an-attrset";});
    nonListNamedCheckRejected = fails (consumer {nativeCheckInputs = "native";} {});
    nonListNamedLintRejected = fails (consumer {lintNativeBuildInputs = "native";} {});
    checkEnvironmentNamesRejected = fails (consumer {checkEnv.PATH = "unsafe";} {});
    mergedCheckInputsPreserved = (consumer {} {nativeCheckInputs = [a];}).compileAttrs.nativeBuildInputs == [a];
    mergedLintInputsPreserved = (consumer {} {lintNativeBuildInputs = [b];}).compileAttrs.nativeBuildInputs == [b];
    namedInputsAppendMerged =
      (consumer {
          nativeCheckInputs = [b];
          lintNativeBuildInputs = [a];
        } {
          nativeCheckInputs = [a];
          lintNativeBuildInputs = [b];
        }).compileAttrs.nativeBuildInputs
      == [b a a b];
    environmentRejectedAtRecordBoundary = !(builtins.tryEval (consumer {buildAttrs.env.HOME = "unsafe";} {})).success;
    badEnvironmentRejectedViaPackaging = !(builtins.tryEval (consumer {buildAttrs.env.OPENSSL_DIR = false;} {}).packagingAttrs).success;
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-compile-context failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }
