# Manifest identity integration only; shared export fixtures own Rust semantics.
{pkgs}: let
  loader = import ../../packages.nix;
  original = loader {inherit pkgs;};
  explicitEmpty = loader {
    inherit pkgs;
    externalPackagesFor = _: {};
  };
  src = ../../rust/tests/fixtures/exports;
  exporter = import ../../rust/export.nix {
    inherit src;
    memberDirs = ["members/agent" "members/manager"];
    packageFile = src + "/members/manager/default.nix";
  };
  target = "example-hello-rust";
  adopted = loader {
    inherit pkgs;
    externalPackagesFor = _system: {${target} = exporter.mkPackage;};
  };
  direct = exporter.mkPackage {inherit pkgs;};
  supplied = loader {
    inherit pkgs;
    externalPackagesFor = _: {${target} = direct;};
  };
  bad = replacements:
    (loader {
      inherit pkgs;
      externalPackagesFor = _: replacements;
    }).packages.${
      target
    };
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  assertions = {
    emptyDefaultIdentity = original.packages.${target}.drvPath == explicitEmpty.packages.${target}.drvPath;
    originalDefinitionOwnedDefault = original.packages.${target}.pname == "hello-rust";
    functionalProvider = adopted.packages.${target}.drvPath == direct.drvPath;
    derivationProvider = supplied.packages.${target}.drvPath == direct.drvPath;
    rootAppFollowsOverride = adopted.rootApps.${target}.drvPath == direct.drvPath;
    unrelatedDefaultUnchanged = adopted.packages.abird-host-agent.drvPath == original.packages.abird-host-agent.drvPath;
    unknownNameRejects = fails (bad {not-a-canonical-package = direct;});
    nullRejects = fails (bad {${target} = null;});
    opaqueRejects = fails (bad {${target} = {drvPath = direct.drvPath;};});
    malformedProviderRejects = fails (bad []);
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "externalPackagesFor failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }
