# Evaluation-only integration coverage using the caller's real pinned Crane.
# No Rust compilation and no import-from-derivation are needed for these checks.
{pkgs}: let
  helper = import ../../pkg-helper.nix;
  resolver = import ../../rust/toolchain.nix;
  seed = pkgs.extend (resolver {}).overlay;
  tool = pkgs.symlinkJoin {
    name = "rust-toolchain-integration";
    paths = [pkgs.rustc pkgs.cargo pkgs.clippy pkgs.rustfmt];
  };
  contract = {
    provider = "resolved";
    derivation = tool;
  };
  overridden = seed.extend (_final: prev: {
    craneLib = prev.craneLib.overrideToolchain tool;
  });
  selected = overridden.rustToolchainFor null;
  direct = (resolver {pkgs = pkgs // {craneLib = overridden.craneLib;};}).toolchainFor null;
  package = args:
    helper.mkRustDerivation ({
        pkgs = seed;
        src = ../../../..;
        projectDir = "pkgs/examples/hello-rust";
        pname = "hello-rust";
      }
      // args);
  custom = package {toolchain = contract;};
  lateDefault = package {
    pkgs = overridden;
    enableDevShell = true;
  };
  crossPkgsFor = p:
    if p.stdenv.buildPlatform.isAarch64
    then p.pkgsCross.gnu64
    else p.pkgsCross.aarch64-multiplatform;
  crossPkgs = crossPkgsFor pkgs;
  crossStdenv = crossPkgs.stdenv;
  defaultCrossLibrary = seed.craneLib.override (args: builtins.mapAttrs (name: value: crossPkgs.${name} or value) args);
  defaultCross = (resolver {pkgs = crossPkgs // {craneLib = defaultCrossLibrary;};}).toolchainFor null;
  crossLibrary = overridden.extend (_final: prev: {
    craneLib = prev.craneLib.overrideScope (_f: _p: {
      stdenvSelector = _: crossStdenv;
    });
  });
  boundCrossLibrary = seed.extend (_final: prev: {
    craneLib =
      (prev.craneLib.overrideScope (_f: _p: {
        pkgs = crossPkgs;
      })).overrideToolchain
      tool;
  });
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  fmtArgs = {src = ../../../../pkgs/examples/hello-rust;};
  results = {
    defaultCrossLibraryPreserved = defaultCross.craneLib == defaultCrossLibrary && !defaultCross.custom;
    lateOverrideLibrary = selected.craneLib.cargoFmt fmtArgs == overridden.craneLib.cargoFmt fmtArgs;
    lateOverrideCompiler = selected.toolPkgs.rustc == tool && selected.toolPkgs.cargo == tool;
    directOverrideOperations = direct.toolPkgs.clippy == tool && direct.toolPkgs.rustfmt == tool;
    lateDefaultIdentity = lateDefault.passthru.rustToolchainId == selected.id;
    providerIndependentIdentity = selected.id == custom.passthru.rustToolchainId;
    lateDefaultShell = builtins.elem tool lateDefault.passthru.devShell.nativeBuildInputs;
    lateDefaultCraneCheck = builtins.elem tool lateDefault.passthru.checks.lint.nativeBuildInputs;
    customBuildInputs = builtins.elem tool custom.nativeBuildInputs;
    compilerOverrideRejected =
      fails
      (package {
        toolchain = contract;
        buildAttrs.env.RUSTC = "/compiler-b/bin/rustc";
      }).passthru.rustToolchainId;
    wrapperOverrideRejected =
      fails
      (package {
        toolchain = contract;
        RUSTC_WRAPPER = "/compiler-wrapper";
      }).outPath;
    crossBuildOverrideRejected =
      fails
      (package {
        toolchain = contract;
        buildAttrs.stdenv = crossStdenv;
      }).outPath;
    crossLibrarySelectorRejected = fails (crossLibrary.rustToolchainFor null).id;
    crossLibraryBindingRejected = fails (boundCrossLibrary.rustToolchainFor null).id;
    crossFunctionBuildOverrideRejected =
      fails
      (package {
        toolchain = contract;
        buildAttrs.stdenv = p: (crossPkgsFor p).stdenv;
      }).outPath;
    nativeFunctionBuildOverrideAccepted = (seed.rustToolchainFor contract).validateBuildAttrs {stdenv = p: p.stdenv;};
    trunkCompilerOverrideRejected =
      fails
      (helper.mkTrunkProject {
        pkgs = seed;
        src = ../../../..;
        pname = "trunk-integration";
        toolchain = contract;
        buildAttrs.env.RUSTC = "/compiler-b/bin/rustc";
      }).outPath;
    legacyIsolatedCustomDefaultRejected =
      fails
      (helper.mkCargoWorkspacePackage {
        pkgs = overridden;
        src = ../../../../pkgs/examples/hello-rust-isolated;
        pname = "hello-rust-isolated";
      }).outPath;
  };
in
  assert (pkgs.craneLib or null) != null;
  assert builtins.all (name:
    if results.${name}
    then true
    else throw "rust-toolchain integration failed: ${name}") (builtins.attrNames results);
    pkgs.runCommand "pvl-rust-toolchain-integration-test" {passthru = {assertions = results;};} ''
      touch "$out"
    ''
