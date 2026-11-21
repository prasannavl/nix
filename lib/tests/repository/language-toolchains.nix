{pkgs}: let
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  rustDefault = pkgs.toolchains.rust null;
  goDefault = pkgs.toolchains.go null;
  goExact = pkgs.toolchains.go {version = "1.27.4";};
  standaloneGo = import ../../../ab/core/packaging/go/toolchain.nix {inherit pkgs;};
  nodeDefault = pkgs.toolchains.node null;
  node24 = pkgs.toolchains.node {version = "24";};
  pythonDefault = pkgs.toolchains.python null;
  python314 = pkgs.toolchains.python {version = "3.14";};
  denoDefault = pkgs.toolchains.deno null;
  cross =
    if pkgs.stdenv.buildPlatform.isx86_64
    then pkgs.pkgsCross.aarch64-multiplatform
    else pkgs.pkgsCross.gnu64;
  late = pkgs.extend (_final: prev: {
    go = prev.go_1_27;
    nodejs = prev.nodejs_22;
    python3 = prev.python314;
  });

  sameShape = toolchain:
    builtins.all (name: builtins.hasAttr name toolchain) [
      "pkg"
      "tools"
      "build"
      "provider"
      "id"
      "custom"
    ];

  results = {
    uniformShape = builtins.all sameShape [
      rustDefault
      goDefault
      nodeDefault
      pythonDefault
      denoDefault
    ];
    rustPkg = pkgs.lib.isDerivation rustDefault.pkg;
    rustTools =
      rustDefault.tools.rustc
      == rustDefault.build.pkgs.rustc
      && rustDefault.tools.cargo == rustDefault.build.pkgs.cargo;
    rustBuild =
      rustDefault.build.crane.cargoFmt {src = ../../../pkgs/examples/hello-rust;}
      != null
      && rustDefault.build.validate {};

    goDefault =
      goDefault.pkg
      == pkgs.go
      && goDefault.provider == "nixpkgs"
      && !goDefault.custom;
    goExact = goExact.pkg.version == "1.27.4";
    goProvider = builtins.elem goExact.provider ["nixpkgs" "go-overlay"];
    goOverlay =
      (pkgs.toolchains.go {
        provider = "go-overlay";
        version = "1.27.4";
      }).provider
      == "go-overlay";
    goProviderHidden = !(pkgs ? go-bin);
    standaloneGoDefault = (standaloneGo.toolchainFor null).pkg == pkgs.go;
    standaloneGoProviderMissing =
      fails
      (standaloneGo.toolchainFor {
        provider = "go-overlay";
        version = "1.27.4";
      }).id;
    resolvedGo = let
      selected = pkgs.toolchains.go {
        provider = "resolved";
        pkg = pkgs.go;
      };
    in
      selected.pkg
      == pkgs.go
      && selected.provider == "resolved"
      && selected.id == goDefault.id;

    nodeDefault = nodeDefault.pkg == pkgs.nodejs && !nodeDefault.custom;
    node24 = node24.pkg.version == pkgs.nodejs_24.version;

    pythonDefault = pythonDefault.pkg == pkgs.python3 && !pythonDefault.custom;
    python314 = python314.pkg.version == pkgs.python314.version;
    pythonPackages = python314.build.pkgs.python == python314.pkg;
    pythonBuilders =
      python314.build.pkg
      == python314.build.pkgs.buildPythonPackage
      && python314.build.app == python314.build.pkgs.buildPythonApplication;

    denoDefault = denoDefault.pkg == pkgs.deno && !denoDefault.custom;
    denoBuildEmpty = denoDefault.build == {};
    goBuild = goExact.build.mod != null;
    nodeBuild = node24.build.npm != null;

    lateGo = (late.toolchains.go null).pkg == late.go;
    lateNode = (late.toolchains.node null).pkg == late.nodejs;
    latePython = (late.toolchains.python null).pkg == late.python3;

    unavailableNode = fails (pkgs.toolchains.node {version = "24.0.0";}).id;
    removedNode = fails (pkgs.toolchains.node {version = "20";}).id;
    malformedPython = fails (pkgs.toolchains.python {version = "3";}).id;
    unavailablePython = fails (pkgs.toolchains.python {version = "3.14.0";}).id;
    unavailableDeno = fails (pkgs.toolchains.deno {version = "0.0.0";}).id;
    unknownProvider = fails (pkgs.toolchains.go {provider = "unknown";}).id;
    malformedProvider = fails (pkgs.toolchains.go {provider = 1;}).id;
    malformedVersion = fails (pkgs.toolchains.python {version = 3.14;}).id;
    missingResolved = fails (pkgs.toolchains.node {provider = "resolved";}).id;
    nonDerivation =
      fails
      (pkgs.toolchains.deno {
        provider = "resolved";
        pkg = {};
      }).id;
    missingGoOverlayVersion = fails (pkgs.toolchains.go {provider = "go-overlay";}).id;
    unknownField = fails (pkgs.toolchains.node {channel = "lts";}).id;
    crossGoDefault = (cross.toolchains.go null).pkg == cross.go;
    crossGoOverlay =
      fails
      (cross.toolchains.go {
        provider = "go-overlay";
        version = "1.27.4";
      }).id;
  };
in
  assert builtins.all (name:
    if results.${name}
    then true
    else throw "language-toolchain test failed: ${name}") (builtins.attrNames results);
    pkgs.runCommand "lib-flake-language-toolchains-test" {
      passthru.assertions = results;
    } ''
      touch "$out"
    ''
