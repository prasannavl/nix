{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10d" (root + "/ab/core");
  repoSource = isolated "ab-repo-phase10d" (root + "/ab/repo");
  fixtureSource = isolated "ab-external-repo-fixture" (root + "/ab/tests/fixtures/external-repo");

  fixture = import fixtureSource {
    abCoreSource = coreSource;
    abRepoSource = repoSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };

  packageSet = fixture.packages.packages;
  base = packageSet.base;
  alias = packageSet.base-alias;
  dependent = packageSet.dependent;
  packageOpsManifest = fixture.tasks.packageOps.manifest.packages;
  repoCheck = fixture.checks.external-repository;
in
  assert fixture.core.name == "ab-core";
  assert fixture.repoComponent.name == "ab-repo";
  assert fixture.repoComponent.dependencies
  == {
    required = ["core"];
    optional = [];
  };
  assert builtins.attrNames fixture.repoComponent.projections == ["fold" "services" "specifications"];
  assert builtins.attrNames (fixture.repoComponent.projections.services {
    serviceStack = {
      isServiceRegistry = registry:
        builtins.isAttrs registry
        && builtins.isAttrs (registry.roles or null)
        && builtins.isAttrs (registry.services or null);
      isServiceStack = stack:
        builtins.isAttrs stack
        && builtins.isAttrs (stack.serviceRegistry or null);
      applyServiceRoleOverrides = stack: roleOverrides:
        if roleOverrides == {}
        then stack
        else stack // stack.withServiceRoles roleOverrides;
    };
  })
  == ["adapters" "admission" "layout" "moves" "placements"];
  assert builtins.functionArgs fixture.repoComponent.config
  == {
    defaultScope = true;
    families = false;
    modules = true;
    nix = true;
    projectionDomainExtensions = true;
    projectionRuntimeAdapters = true;
    shared = false;
  };
  assert fixture.ab ? repo;
  assert !(fixture.ab ? runtime);
  assert !(fixture.ab ? services);
  assert !(builtins.hasAttr "abird-host-agent" fixture.pkgs);
  assert builtins.attrNames fixture.packages.canonicalPackages == ["base" "dependent"];
  assert builtins.attrNames fixture.packages.packageAliases == ["base-alias"];
  assert builtins.attrNames packageSet == ["base" "base-alias" "dependent"];
  assert base.drvPath == alias.drvPath;
  assert base.repoVisible == false;
  assert dependent.base.drvPath == base.drvPath;
  assert fixture.packages.rootApps.base.drvPath == base.drvPath;
  assert builtins.map (entry: entry.name) packageOpsManifest == ["base" "base-alias"];
  assert builtins.all (entry: entry.path == "base") packageOpsManifest;
  assert builtins.length fixture.tasks.packageOps.runtimeInputs == 1;
  assert (builtins.head fixture.tasks.packageOps.runtimeInputs).drvPath == fixture.pkgs.hello.drvPath;
  assert builtins.attrNames fixture.tasks.apps == ["fmt" "lint"];
  assert builtins.attrNames fixture.tasks.packages == ["fmt" "lint"];
  assert repoCheck.name == "ab-external-repository-check";
    pkgs.runCommand "abird-external-repo-fixture" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      test -x ${base}/bin/external-repo-base
      test "$(${base}/bin/external-repo-base)" = "external-repo-base"
      test "$(cat ${dependent}/name)" = "external-repo-dependent"
      test -e ${repoCheck}

      test "$(${fixture.tasks.apps.fmt.program})" = "external-repo-fmt"
      test "$(${fixture.tasks.apps.lint.program})" = "external-repo-lint"

      bash ${./audit-component-source.sh} ${repoSource}

      if rg -n 'ab/(runtime|services|stack)|hosts/|config/|lib/flake|overlays/|pkgs/' ${fixtureSource}; then
        echo "external repository fixture reaches undeclared repository source" >&2
        exit 1
      fi

      touch "$out"
    ''
