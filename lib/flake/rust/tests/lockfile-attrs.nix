# Pure recording-platform coverage for ordinary builder lockfile ownership.
# Run with nix eval --offline --option allow-import-from-derivation false --json
# --file lib/flake/rust/tests/lockfile-attrs.nix.
let
  helper = import ../../pkg-helper.nix;
  fixture = ./fixtures/lockfile;
  alternateFixture = ./fixtures/workspace;
  originalLock = builtins.readFile (fixture + "/Cargo.lock");
  alternateLock = builtins.readFile (alternateFixture + "/Cargo.lock");
  changedLock = originalLock + "# effective lock override\n";
  # Reading/realizing this source is forbidden; only its identity is available.
  opaque = {
    type = "derivation";
    outPath = "/nix/store/00000000000000000000000000000000-unrealized-lock-source";
    drvPath = throw "lockfile normalization must not realize an opaque source";
  };
  baseAttrs = {
    pname = "lockfile-control";
    src = fixture;
    cargoLock.lockFileContents = originalLock;
  };
  record = attrs: fallbackAttrs:
    helper.mkCraneRustPackage {
      inherit attrs fallbackAttrs;
      rustPlatform.buildRustPackage = value: value;
    };
  unchanged = record baseAttrs {};
  changed = record (baseAttrs // {cargoLock.lockFileContents = changedLock;}) {};
  callerHook = "touch caller-post-patch";
  withCallerHooks = record (baseAttrs
    // {
      cargoLock.lockFileContents = changedLock;
      postPatch = callerHook;
      passAsFile = ["callerPayload"];
      callerPayload = "caller data";
      cargoRoot = "members/application";
    }) {};
  opaqueOverride = record baseAttrs {src = opaque;};
  opaqueAttrs = baseAttrs // {src = opaque;};
  opaqueDirect = record opaqueAttrs {};
  pathOverride = record baseAttrs {src = alternateFixture;};
  matchingPathAttrs =
    baseAttrs
    // {
      src = alternateFixture;
      cargoLock.lockFileContents = alternateLock;
    };
  depsOverrideAttrs =
    baseAttrs
    // {
      cargoDeps = opaque;
      cargoLock.lockFileContents = changedLock;
    };
  vendorOverrideAttrs =
    baseAttrs
    // {
      cargoVendorDir = "caller-vendor";
      cargoLock.lockFileContents = changedLock;
    };
  noLockAttrs = builtins.removeAttrs baseAttrs ["cargoLock"];
  fileLockAttrs = baseAttrs // {cargoLock = {lockFile = fixture + "/Cargo.lock";};};
  results = {
    unchangedInlineLockPreservesAllAttrs = unchanged == baseAttrs;
    unchangedInlineLockAddsNoInstaller = !(unchanged ? rustPlatformLockfile);
    absentLockPreservesAllAttrs = record noLockAttrs {} == noLockAttrs;
    nullLockPreservesAllAttrs = let
      attrs = baseAttrs // {cargoLock = null;};
    in
      record attrs {} == attrs;
    fileOnlyLockPreservesAllAttrs = record fileLockAttrs {} == fileLockAttrs;
    differentFileLockInstallsSuppliedContents =
      (record (baseAttrs // {cargoLock = {lockFile = alternateFixture + "/Cargo.lock";};}) {}).rustPlatformLockfile == alternateLock;
    cargoRootCannotUseOuterLockExemption =
      (record (baseAttrs // {cargoRoot = "members/app";}) {}).rustPlatformLockfile == originalLock;
    changedInlineLockInstallsExactContents = changed.rustPlatformLockfile == changedLock;
    changedInlineLockUsesFileTransport = changed.passAsFile == ["rustPlatformLockfile"];
    changedInlineLockKeepsVendorDefinition = changed.cargoLock.lockFileContents == changedLock;
    callerPostPatchRunsBeforeInstallation =
      builtins.substring 0 (builtins.stringLength callerHook + 1) withCallerHooks.postPatch == callerHook + "\n";
    callerFileTransportIsPreserved = withCallerHooks.passAsFile == ["callerPayload" "rustPlatformLockfile"];
    callerFilePayloadIsPreserved = withCallerHooks.callerPayload == "caller data";
    unchangedLockPreservesCallerHooksExactly = let
      attrs =
        baseAttrs
        // {
          postPatch = callerHook;
          passAsFile = ["callerPayload"];
          callerPayload = "caller data";
        };
    in
      record attrs {} == attrs;
    callerCargoRootIsPreserved = withCallerHooks.cargoRoot == "members/application";
    installationHonorsCargoRoot =
      builtins.match ".*cargoRoot.*" (builtins.replaceStrings ["\n"] [" "] withCallerHooks.postPatch) != null;
    opaqueSourceOverrideCannotUseOriginalLockExemption = opaqueOverride.rustPlatformLockfile == originalLock;
    opaqueSourceOverrideIsPreserved = opaqueOverride.src.outPath == opaque.outPath;
    opaqueOriginalSourceInstallsWithoutRealization = opaqueDirect.rustPlatformLockfile == originalLock;
    opaqueSourceWithoutInlineLockStaysOpaque =
      (record (builtins.removeAttrs opaqueAttrs ["cargoLock"]) {}).src.outPath == opaque.outPath;
    pathOverrideUsesActualSourceLock = pathOverride.rustPlatformLockfile == originalLock;
    matchingPathOverridePreservesAllAttrs =
      record baseAttrs {
        src = alternateFixture;
        cargoLock.lockFileContents = alternateLock;
      }
      == matchingPathAttrs;
    cargoDepsOwnsVendoringAndPreservesAllAttrs = record depsOverrideAttrs {} == depsOverrideAttrs;
    cargoVendorDirOwnsVendoringAndPreservesAllAttrs = record vendorOverrideAttrs {} == vendorOverrideAttrs;
    fallbackCargoDepsOverrideOwnsVendoring = !(record (baseAttrs // {cargoLock.lockFileContents = changedLock;}) {cargoDeps = opaque;} ? rustPlatformLockfile);
    fallbackCargoVendorDirOverrideOwnsVendoring = !(record (baseAttrs // {cargoLock.lockFileContents = changedLock;}) {cargoVendorDir = "caller-vendor";} ? rustPlatformLockfile);
    nullVendorOverridesRetainInlineLockOwnership =
      (record (baseAttrs
        // {
          cargoLock.lockFileContents = changedLock;
          cargoDeps = null;
          cargoVendorDir = null;
        }) {}).rustPlatformLockfile
      == changedLock;
  };
in
  assert originalLock != alternateLock;
  assert builtins.all (name:
    if results.${name}
    then true
    else throw "rust lockfile attrs check failed: ${name}") (builtins.attrNames results); results
