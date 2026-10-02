{
  pkgs,
  crane,
}: let
  # Test expectations derive from existing manifest definitions/selectors.
  # Production children simply call their own definition: no routing registry.
  root = ../../../..;
  manifest = (import ../../../../pkgs/manifest.nix).packages;
  routeCandidates = builtins.concatMap (name: let
    entry = manifest.${name};
    definition =
      if builtins.isPath entry
      then entry
      else entry.path;
    directory = toString (builtins.dirOf definition);
    route = output: file: {
      name = pkgs.lib.removePrefix "${toString root}/" file;
      value = {
        package = name;
        output = output;
      };
    };
  in
    [(route [] "${directory}/flake.nix")]
    ++ pkgs.lib.mapAttrsToList (_: output:
      route output "${directory}/${builtins.concatStringsSep "/" output}/flake.nix")
    (
      if builtins.isPath entry
      then {}
      else entry.toolingPackages or {}
    )) (builtins.attrNames manifest);
  existingRoutes = builtins.filter (route: builtins.pathExists (root + "/${route.name}")) routeCandidates;
  children = builtins.listToAttrs existingRoutes;
  stack = import ../../stack/package.nix;
  helper = import ../../pkg-helper.nix;
  system = pkgs.stdenv.hostPlatform.system;
  flakeUtils.lib = {
    defaultSystems = [system];
    eachSystem = systems: f:
      builtins.foldl' (outputs: name:
        builtins.foldl' (result: key:
          result // {${key} = (result.${key} or {}) // {${name} = (f name).${key};};})
        outputs (builtins.attrNames (f name))) {}
      systems;
  };
  inputs = {
    nixpkgs = {
      outPath = pkgs.path;
      lib = pkgs.lib;
      legacyPackages.${system} = import pkgs.path {inherit system;};
    };
    flake-utils = flakeUtils;
    inherit crane;
  };
  # Bound independent nixpkgs imports: default-construction smoke coverage is
  # hello-rust (Crane/artifacts), manager (internalDeps), and nested llmug
  # (custom outputs). All retained wrappers still get actual outputs evaluation
  # and canonical parity with the parent's injected package set below.
  # Independent defaults compare with identical construction, not arbitrary
  # parent overlays. Input declarations for every wrapper are checked too.
  defaultPkgs = import pkgs.path {
    inherit system;
    overlays = [(import ../../rust-toolchain.nix {inputs = {inherit crane;};}).overlay];
  };
  parentPackages = (import ../../packages.nix {inherit pkgs;}).packages;
  defaultPackages = (import ../../packages.nix {pkgs = defaultPkgs;}).packages;
  plainPkgs = inputs.nixpkgs.legacyPackages.${system};
  plainPackages = (import ../../packages.nix {pkgs = plainPkgs;}).packages;
  canonical = packages: route:
    pkgs.lib.attrByPath route.output
    (throw "child parity: invalid canonical selector")
    packages.${route.package};
  wrappers = builtins.mapAttrs (path: _: import (root + "/${path}")) children;
  # Feed ONLY declared inputs. Supplying Crane to every test wrapper concealed
  # missing declarations and forced non-Rust defaults through a Rust overlay.
  inputsFor = wrapper: builtins.mapAttrs (name: _: inputs.${name}) wrapper.inputs;
  injectedOutputs = builtins.mapAttrs (_: wrapper:
    wrapper.outputs (inputsFor wrapper // {pkgsForSystem = _: pkgs;}))
  wrappers;
  # Current direct Rust producers publish compiler identity; parity below also
  # exercises the dependency closure. No new production capability flag/list.
  rustPaths = builtins.filter (path: (canonical parentPackages children.${path}) ? rustToolchainId) (builtins.attrNames children);
  nonRustPaths = builtins.filter (path: !(builtins.elem path rustPaths)) (builtins.attrNames children);
  smokePaths =
    [
      "pkgs/examples/hello-rust/flake.nix"
      "pkgs/tools/abird-host-manager/flake.nix"
    ]
    ++ nonRustPaths;
  defaultOutputs = builtins.listToAttrs (map (path: {
      name = path;
      value = wrappers.${path}.outputs (inputsFor wrappers.${path});
    })
    smokePaths);
  defaultContextFor = path:
    if wrappers.${path}.inputs ? crane
    then {
      pkgs = defaultPkgs;
      packages = defaultPackages;
    }
    else {
      pkgs = plainPkgs;
      packages = plainPackages;
    };
  craneUrl = (import ../../../../flake.nix).inputs.crane.url;
  declaresCrane = path: (wrappers.${path}.inputs.crane.url or null) == craneUrl;
  # Force all exported derivation paths and app programs, not just the default.
  outputPaths = outputs: {
    packages = builtins.mapAttrs (_: drv: drv.drvPath) outputs.packages.${system};
    checks = builtins.mapAttrs (_: drv: drv.drvPath) (outputs.checks.${system} or {});
    apps = builtins.mapAttrs (_: app: app.program) (outputs.apps.${system} or {});
    devShells = builtins.mapAttrs (_: drv: drv.drvPath) (outputs.devShells.${system} or {});
    modules = builtins.attrNames (outputs.nixosModules or {});
  };
  # Compare every observable output path/program, not just force evaluation.
  # Module names are comparable; evaluating NixOS module bodies is a separate
  # acceptance gate. Nested wrapper extras are explicit repository-owned facts.
  expectedPaths = packagePkgs: packages: path: let
    build = canonical packages children.${path};
    extra = packagePkgs.lib.optionalAttrs (children.${path}
      == {
        package = "cloudflare-apps";
        output = ["llmug-hello"];
      }) {
      extraPackages.wrangler-deploy = build.wrangler-deploy;
      extraApps.wrangler-deploy = helper.mkPackageApp packagePkgs build.wrangler-deploy;
    };
    standard = helper.mkStdFlakeOutputs ({
        pkgs = packagePkgs;
        build = build;
      }
      // extra);
    globalModules = helper.mkNixosModuleAttrs {build = build;};
    modules =
      if globalModules != {}
      then globalModules
      else packagePkgs.lib.optionalAttrs (standard ? nixosModules) {${system} = standard.nixosModules;};
  in {
    packages = builtins.mapAttrs (_: drv: drv.drvPath) standard.packages;
    checks = builtins.mapAttrs (_: drv: drv.drvPath) (standard.checks or {});
    apps = builtins.mapAttrs (_: app: app.program) (standard.apps or {});
    devShells = builtins.mapAttrs (_: drv: drv.drvPath) (standard.devShells or {});
    modules = builtins.attrNames modules;
  };
  equal = outputs: packagePkgs: packages: path:
    outputPaths outputs.${path} == expectedPaths packagePkgs packages path;
  # All 13 parent-injected wrappers; independent construction for two Rust
  # smokes and every non-Rust child, with its actual declared input subset.
  allOutputPaths = builtins.mapAttrs (_: outputPaths) injectedOutputs;
  smokeOutputPaths = builtins.mapAttrs (_: outputPaths) defaultOutputs;
  fails = value: !(builtins.tryEval value).success;
  helloFile = ../../../../pkgs/examples/hello-rust/default.nix;
  injectedArgs = {
    nixpkgs = throw "injected package set must not evaluate nixpkgs";
    crane = throw "injected package set must not evaluate crane";
    flake-utils = flakeUtils;
    pkgsForSystem = _: pkgs;
  };
  customizations = [
    {overlays = [(_: _: {})];}
    {rustToolchainInputs = {fenix = {};};}
    {rustToolchainProviders = {custom = _: null;};}
  ];
  # Resolver injection can use an otherwise invalid/nonexistent package file.
  # The generic helper must not evaluate repository registration or the file.
  customResolver =
    stack.mkFlakeOutputs /nonexistent/standalone-package.nix
    (injectedArgs // {packageFor = _: parentPackages.example-hello-rust;});
  # callPackage also accepts definitions, so this has no repository source path
  # or canonical registration at all, while still receiving the generic stack.
  standalone = stack.mkFlakeOutputs ({
    runCommand,
    stack,
  }:
    assert stack.stackName == "package";
      runCommand "standalone-child" {} ''touch "$out"'')
  injectedArgs;
  nested = defaultOutputs."pkgs/cloudflare-apps/llmug-hello/flake.nix";
  hello = defaultOutputs."pkgs/examples/hello-rust/flake.nix";
  expectedHello = defaultPackages.example-hello-rust;
  helloPath = "pkgs/examples/hello-rust/flake.nix";
  # A missing declaration must not be rescued by the test's available Crane
  # input. The bare fallback is valid, but cannot pass the Rust artifact gate.
  helloWithoutCrane = wrappers.${helloPath} // {inputs = builtins.removeAttrs wrappers.${helloPath}.inputs ["crane"];};
  fallbackHello = helloWithoutCrane.outputs (inputsFor helloWithoutCrane);
  parentHello = injectedOutputs.${helloPath};
  rejectsWrongOutputs = wrong:
    !(equal {${helloPath} = wrong;} pkgs parentPackages helloPath);
  wrongChecks =
    parentHello
    // {
      checks =
        parentHello.checks
        // {
          ${system} =
            parentHello.checks.${system}
            // {
              fmt = parentPackages.abird-host-agent.checks.fmt;
            };
        };
    };
  wrongApps =
    parentHello
    // {
      apps =
        parentHello.apps
        // {
          ${system} =
            parentHello.apps.${system}
            // {
              default = parentHello.apps.${system}.default // {program = pkgs.lib.getExe parentPackages.abird-host-agent;};
            };
        };
    };
  wrongShells =
    parentHello
    // {
      devShells.${system}.default = pkgs.mkShell {packages = [pkgs.git];};
    };
  managerFile = ../../../../pkgs/tools/abird-host-manager/default.nix;
  agentFile = ../../../../pkgs/tools/abird-host-agent/default.nix;
  manager = parentPackages.abird-host-manager;
  explicitManager = pkgs.callPackage managerFile {abirdHostAgent = parentPackages.abird-host-agent;};
  sourceOnlyManager = pkgs.callPackage managerFile {abirdHostAgent = null;};
  legacyManager = inputs.nixpkgs.legacyPackages.${system}.callPackage managerFile {};
  # A dependency default must propagate a supplied helper, not silently import
  # the stock helper. This harmless Cargo environment change distinguishes the
  # agent artifact path without selecting another compiler or building anything.
  taggedHelper =
    helper
    // {
      mkRustDerivation = args:
        helper.mkRustDerivation (args
          // pkgs.lib.optionalAttrs (args.pname == "abird-host-agent") {
            buildAttrs = args.buildAttrs // {env.CARGO_BUILD_JOBS = "1";};
          });
    };
  taggedAgent = pkgs.callPackage agentFile {pkgHelper = taggedHelper;};
  taggedManager = pkgs.callPackage managerFile {pkgHelper = taggedHelper;};
  explicitTaggedManager = pkgs.callPackage managerFile {
    pkgHelper = taggedHelper;
    abirdHostAgent = taggedAgent;
  };
  explicitCloudflare = pkgs.callPackage ../../../../pkgs/cloudflare-apps/default.nix {
    nixbot = parentPackages.nixbot;
    llmugHello = parentPackages.cloudflare-apps.llmug-hello;
  };
in
  assert (pkgs.craneLib or null) != null;
  assert children != {};
  # Multiple manifest variants must not silently select the first expectation.
  assert builtins.length existingRoutes == builtins.length (builtins.attrNames children);
  assert builtins.all declaresCrane rustPaths;
  assert builtins.all (path: !(wrappers.${path}.inputs ? crane)) nonRustPaths;
  assert builtins.all (path: let
    build = injectedOutputs.${path}.packages.${system}.default;
  in
    build ? cargoArtifacts && build.rustToolchainId == (canonical parentPackages children.${path}).rustToolchainId)
  rustPaths;
  assert builtins.all (path:
    if equal injectedOutputs pkgs parentPackages path
    then true
    else throw "child parity: parent-injected outputs differ from canonical exports for ${path}") (builtins.attrNames children);
  assert builtins.all (path: let
    context = defaultContextFor path;
  in
    if equal defaultOutputs context.pkgs context.packages path
    then true
    else throw "child parity: independent default outputs differ from canonical exports for ${path}")
  smokePaths;
  assert builtins.deepSeq allOutputPaths true;
  assert builtins.deepSeq smokeOutputPaths true;
  assert builtins.all rejectsWrongOutputs [wrongChecks wrongApps wrongShells];
  assert builtins.all (customization:
    fails (stack.mkFlakeOutputs helloFile (injectedArgs // customization)))
  customizations;
  assert customResolver.packages.${system}.default.drvPath == parentPackages.example-hello-rust.drvPath;
  assert standalone.packages.${system}.default.name == "standalone-child";
  assert (stack.mkFlakeOutputs helloFile injectedArgs).packages.${system}.default.drvPath
  == (stack.packageFor {
    inherit pkgs;
    packageFile = helloFile;
  }).drvPath;
  # Root/default dependency wiring agrees with the old explicit injection on
  # identical sources/arguments; explicit overrides and source-only mode remain.
  # Bare callPackage without Crane remains valid; flake wrappers supply Crane.
  assert builtins.isString legacyManager.drvPath;
  assert manager.drvPath == explicitManager.drvPath;
  assert manager.cargoArtifacts.drvPath == explicitManager.cargoArtifacts.drvPath;
  assert manager.memberLayer.drvPath == explicitManager.memberLayer.drvPath;
  assert manager.cargoArtifacts.drvPath != sourceOnlyManager.cargoArtifacts.drvPath;
  # Inspect the evaluator-visible input, never build the source laundering drv.
  assert builtins.pathExists "${sourceOnlyManager.src.src}/pkgs/tools/abird-host-agent/Cargo.toml";
  assert taggedAgent.memberLayer.drvPath != parentPackages.abird-host-agent.memberLayer.drvPath;
  assert taggedManager.cargoArtifacts.drvPath == explicitTaggedManager.cargoArtifacts.drvPath;
  assert taggedManager.cargoArtifacts.drvPath != manager.cargoArtifacts.drvPath;
  assert parentPackages.cloudflare-apps.drvPath == explicitCloudflare.drvPath;
  assert parentPackages.cloudflare-apps.deploy.drvPath == explicitCloudflare.deploy.drvPath;
  assert !(fallbackHello.packages.${system}.default ? cargoArtifacts);
  assert expectedHello ? cargoArtifacts;
  assert hello.packages.${system}.default.cargoArtifacts.drvPath == expectedHello.cargoArtifacts.drvPath;
  assert hello.checks.${system}.fmt.drvPath == expectedHello.checks.fmt.drvPath;
  assert hello.apps.${system}.default.program == pkgs.lib.getExe expectedHello;
  assert hello.nixosModules ? default;
  assert nested.packages.${system}.wrangler-deploy.drvPath == plainPackages.cloudflare-apps.llmug-hello.wrangler-deploy.drvPath;
  assert nested.apps.${system}.wrangler-deploy.program == pkgs.lib.getExe plainPackages.cloudflare-apps.llmug-hello.wrangler-deploy;
    pkgs.runCommand "pvl-child-flake-parity-test" {} ''
      touch "$out"
    ''
