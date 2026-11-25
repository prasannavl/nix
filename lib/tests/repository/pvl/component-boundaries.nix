{pkgs}: let
  abSource = ../../../../ab;
  extract = name: path:
    builtins.path {
      inherit name path;
      filter = path: type: type != "directory" || builtins.baseNameOf path != "tests";
    };
  registrySource = extract "ab-registry-isolated" abSource;
  registry = import registrySource;
  core = registry.core;
  plainPkgs = import pkgs.path {system = pkgs.stdenv.hostPlatform.system;};
  # Constructing any of the contexts (and using system storage) must not
  # require an overlay providing a toolchain resolver.
  args.pkgs = plainPkgs // {toolchains = throw "forced unused toolchains";};
  base = core.mk args;
  composed = registry.forPkgs args;
  repository = import ../../../../ab/tests/fixtures/repository;
  bound = (registry.withRepository (repository
    // {
      externalPackagesFor = _: throw "forced unused repository packages";
    })).forPkgs
  args;
  collision = core.mk (args // {extensions = [(_: {build = {};})];});

  # The five external consumers exercise the other isolated components.
  systemSource = extract "ab-system-isolated" (abSource + "/system");
  system = import systemSource {core = core;};
  systemOnly = core.mk (args // {extensions = [system.extension];});
  partition = systemOnly.system.storage.disko.mkExt4 {
    size = "8G";
    label = "probe";
    mountpoint = "/";
  };
  coreNames = ["build" "flake" "nixos" "package" "tasks" "toolchains"];
  namesWith = extra: builtins.sort builtins.lessThan (coreNames ++ extra);
in
  assert builtins.attrNames registry == ["core" "forPkgs" "repo" "runtime" "services" "stack" "system" "withRepository"];
  assert core.dependencies
  == {
    required = [];
    optional = [];
  };
  assert builtins.attrNames base == coreNames;
  assert base.nixos.registryModule == core.registryModule;
  assert builtins.attrNames composed == namesWith ["runtime" "services" "system"];
  assert builtins.attrNames bound == namesWith ["repo" "runtime" "services" "system"];
  assert builtins.attrNames bound.repo == ["checks" "packages" "root" "tasks"];
  assert bound.repo.root == repository.root;
  assert !(builtins.tryEval (builtins.attrNames collision)).success;
  assert builtins.functionArgs (import systemSource) == {core = false;};
  assert system.name == "ab-system";
  assert system.dependencies
  == {
    required = ["core"];
    optional = [];
  };
  assert builtins.attrNames systemOnly == namesWith ["system"];
  assert partition.size == "8G";
  assert partition.content.format == "ext4";
  assert partition.content.mountpoint == "/";
    pkgs.runCommand "pvl-component-boundaries-test" {nativeBuildInputs = [pkgs.ripgrep];} ''
      bash ${./audit-component-source.sh} ${registrySource}/core
      bash ${./audit-component-source.sh} ${systemSource}
      touch "$out"
    ''
