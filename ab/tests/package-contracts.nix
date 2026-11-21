{pkgs}: let
  abLib = import ../.;
  core = abLib.core;
  ab = core.mk {pkgs = pkgs;};
  dependency = pkgs.hello // {path = throw "withDeps interpreted a derivation as a constructor";};
  values = ab.package.withDeps {
    dependency = dependency;
    optional = null;
    record = {path = "data, not a constructor";};
    unused = throw "withDeps forced an unused dependency";
  } (resolved: builtins.removeAttrs resolved ["unused"]);
  scopedPkgs = pkgs // {scopeMarker = "same-package-context";};
  scope = core.packageScope {pkgs = scopedPkgs;};
  project = core.project {};
  packageFile = ./fixtures/package-scope/dependent.nix;
  direct = scope.callPackage packageFile {};
  child = project.packageFor {
    pkgs = scopedPkgs;
    packageFile = packageFile;
  };
  repository =
    (abLib.withRepository {
      root = ./.;
      manifest.packages.dependent = packageFile;
    }).repo.packagesFor
    scopedPkgs;
  expectedContext = ["build" "flake" "nixos" "package" "tasks" "toolchains"];
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  publish = packages: ((abLib.withRepository {
      root = ./.;
      manifest = {packages = packages;};
    }).repo.packagesFor
    scopedPkgs);
  first = ./fixtures/package-scope/base.nix;
  second = packageFile;
  collisions = [
    (publish {
      a = {
        path = first;
        aliases = ["b"];
      };
      b = second;
    }).packages
    (publish {
      a = {
        path = first;
        aliases = ["same" "same"];
      };
    }).packages
    (publish {
      a = {
        path = first;
        aliases = ["same"];
      };
      b = {
        path = second;
        aliases = ["same"];
      };
    }).packages
    (publish {
      a = {
        path = first;
        toolingPackages.b = [];
      };
      b = second;
    }).stdPackages
    (publish {
      a = {
        path = first;
        toolingPackages.same = [];
      };
      b = {
        path = second;
        toolingPackages.same = [];
      };
    }).toolingPackages
    (publish {
      a = {
        path = first;
        rootApp = true;
        apps.a = [];
      };
    }).rootApps
    (publish {
      a = {
        path = first;
        apps.same = [];
      };
      b = {
        path = second;
        apps.same = [];
      };
    }).rootApps
  ];
  valid = publish {
    a = {
      path = first;
      aliases = ["alias"];
      rootApp = true;
      apps.named = [];
      toolingPackages.tool = [];
    };
    b = second;
  };
  override = scope.callPackage packageFile {dependency = pkgs.hello;};
  sourceOnly = scope.callPackage packageFile {dependency = null;};
in
  assert values.dependency.drvPath == pkgs.hello.drvPath;
  assert values.optional == null;
  assert values.record.path == "data, not a constructor";
  assert direct.drvPath == child.drvPath;
  assert direct.drvPath == repository.packages.dependent.drvPath;
  assert direct.dependency.contextNames == expectedContext;
  assert direct.dependency.marker == "same-package-context";
  assert (scope.pkgs.callPackage first {}).drvPath == (scope.callPackage first {}).drvPath;
  assert override.dependency.drvPath == pkgs.hello.drvPath;
  assert sourceOnly.dependency == null;
  assert builtins.all rejects collisions;
  assert valid.packages.alias.drvPath == valid.packages.a.drvPath;
  assert valid.rootApps.named.drvPath == valid.packages.a.drvPath;
  assert valid.stdPackages.tool.drvPath == valid.packages.a.drvPath;
    pkgs.runCommand "ab-package-contracts-test" {} ''
      touch "$out"
    ''
