# Exercise the real ordinary builder's source/vendor comparison and compilation.
# An explicit lock override replaces a Git identity with a local path dependency.
{pkgs}: let
  helper = import ../../pkg-helper.nix;
  assertions = import ./lockfile-attrs.nix;
  plainPkgs = import pkgs.path {system = pkgs.stdenv.hostPlatform.system;};
  fixture = ./fixtures/lockfile;
  originalLock = builtins.readFile (fixture + "/Cargo.lock");
  sourceLine = ''source = "git+https://example.invalid/locked-library#1111111111111111111111111111111111111111"'' + "\n";
  effectiveLock = builtins.replaceStrings [sourceLine] [""] originalLock;
  package = helper.mkRustDerivation {
    pkgs = plainPkgs;
    src = fixture;
    pname = "lock-app";
    version = "0.1.0";
    projectDir = "members/app";
    deps = ["members/library"];
    cargoLock.lockFileContents = effectiveLock;
    buildAttrs.postPatch = ''
      test -f Cargo.toml
      touch caller-post-patch
    '';
  };
  isolated = helper.mkCargoWorkspacePackage {
    pkgs = plainPkgs;
    src = fixture;
    pname = "lock-app";
    version = "0.1.0";
    cargoPackage = "lock-app";
    cargoLock.lockFileContents = effectiveLock;
  };
  setup = package.overrideAttrs (_old: {
    pname = "rust-lockfile-setup-probe";
    dontBuild = true;
    doCheck = false;
    installPhase = ''
      mkdir -p "$out"
      cp Cargo.lock caller-post-patch "$out/"
    '';
  });
  expected = pkgs.writeText "effective-Cargo.lock" effectiveLock;
in
  assert builtins.deepSeq assertions true;
  assert originalLock != effectiveLock;
    pkgs.runCommand "rust-fallback-lockfile-test" {
      passthru = {inherit assertions isolated package setup;};
    } ''
      test "$(${package}/bin/lock-app)" = lockfile-contract
      test "$(${isolated}/bin/lock-app)" = lockfile-contract
      cmp ${expected} ${setup}/Cargo.lock
      test -f ${setup}/caller-post-patch
      touch "$out"
    ''
