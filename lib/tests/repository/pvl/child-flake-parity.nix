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
    baseName = builtins.baseNameOf definition;
    isDirectoryDefinition = !(pkgs.lib.hasSuffix ".nix" baseName);
    directory =
      if isDirectoryDefinition
      then toString definition
      else toString (builtins.dirOf definition);
    route = output: file: {
      name = pkgs.lib.removePrefix "${toString root}/" file;
      value = {
        package = name;
        output = output;
      };
    };
  in
    pkgs.lib.optional (
      (isDirectoryDefinition || baseName == "default.nix")
      && builtins.pathExists "${directory}/flake.nix"
    ) (route [] "${directory}/flake.nix")
    ++ pkgs.lib.mapAttrsToList (_: output:
      route output "${directory}/${builtins.concatStringsSep "/" output}/flake.nix")
    (
      if builtins.isPath entry
      then {}
      else entry.toolingPackages or {}
    )) (builtins.attrNames manifest);
  existingRoutes = builtins.filter (route: builtins.pathExists (root + "/${route.name}")) routeCandidates;
  allChildren = builtins.listToAttrs existingRoutes;
  # Bounded shared-wrapper output parity, not full product/host evaluation.
  # All Abird wrappers still get declaration/policy checks below.
  portablePaths = [
    "pkgs/cloudflare-apps/flake.nix"
    "pkgs/cloudflare-apps/llmug-hello/flake.nix"
    "pkgs/examples/hello-go/flake.nix"
    "pkgs/examples/hello-node/flake.nix"
    "pkgs/examples/hello-python/flake.nix"
    "pkgs/examples/hello-rust/flake.nix"
    "pkgs/examples/hello-rust-isolated/flake.nix"
    "pkgs/examples/hello-web-static/flake.nix"
    "pkgs/support/nats-http-bridge/flake.nix"
    "pkgs/tools/abird-host-agent/flake.nix"
    "pkgs/tools/abird-host-manager/flake.nix"
    "pkgs/tools/nats-wrecking-ball/flake.nix"
    "pkgs/tools/nixbot/flake.nix"
  ];
  children = pkgs.lib.filterAttrs (path: _: builtins.elem path portablePaths) allChildren;
  allWrappers = builtins.mapAttrs (path: _: import (root + "/${path}")) allChildren;
  rustClosurePaths = portablePaths;
  nonRustPathsAll = [
    "pkgs/cloudflare-apps/flake.nix"
    "pkgs/cloudflare-apps/llmug-hello/flake.nix"
    "pkgs/examples/hello-go/flake.nix"
    "pkgs/examples/hello-node/flake.nix"
    "pkgs/examples/hello-python/flake.nix"
    "pkgs/examples/hello-web-static/flake.nix"
    "pkgs/tools/nixbot/flake.nix"
  ];
  requiresCrane = path: builtins.elem path rustClosurePaths && !(builtins.elem path nonRustPathsAll);
  abCore = import ../../../../ab/core;
  abFor = packagePkgs:
    abCore.mk {
      pkgs = packagePkgs;
      projectRoot = root;
      treefmtConfig = root + "/treefmt.toml";
    };
  project = abCore.project {
    projectRoot = root;
    treefmtConfig = root + "/treefmt.toml";
  };
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
    overlays = [
      (import ../../../../ab/core/packaging/rust/toolchain.nix {inputs = {inherit crane;};}).overlay
      (import ../../../overlays/rust-policy.nix)
    ];
  };
  repoPackagesFor = packagePkgs:
    (import ../../../../lib/repo-context.nix {pkgs = packagePkgs;}).repo.packages.packages;
  parentPackages = repoPackagesFor pkgs;
  defaultPackages = repoPackagesFor defaultPkgs;
  plainPkgs = inputs.nixpkgs.legacyPackages.${system};
  plainPackages = repoPackagesFor plainPkgs;
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
    ab = abFor packagePkgs;
    build = canonical packages children.${path};
    extra = packagePkgs.lib.optionalAttrs (children.${path}
      == {
        package = "cloudflare-apps";
        output = ["llmug-hello"];
      }) {
      extraPackages.wrangler-deploy = build.wrangler-deploy;
      extraApps.wrangler-deploy = ab.flake.app packagePkgs build.wrangler-deploy;
    };
    standard = ab.flake.outputs ({
        pkgs = packagePkgs;
        build = build;
      }
      // extra);
    globalModules = ab.flake.modules {build = build;};
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
  # Policy tests use a tiny non-Rust package: testing a true parent must never
  # select or evaluate the real Abird workspace's unqualified union base.
  policyPackage = pkgs.runCommand "child-policy-fixture" {} ''touch "$out"'';
  trueParentPkgs = pkgs.extend (_final: _prev: {rustWorkspaceDeps = true;});
  policyOutputs = parent: policy:
    project.mkFlakeOutputs helloFile (injectedArgs
      // {
        pkgsForSystem = _: parent;
        rustWorkspaceDeps = policy;
        packageFor = _: policyPackage;
      });
  preservesInjectedPolicy = parent: policy: let
    # A sparse injected set lets us compare its full data without forcing
    # Nixpkgs' throwing deprecated aliases. Guard extension independently;
    # null must preserve even an unevaluated parent policy.
    protectedParent = {
      lib = pkgs.lib;
      rustWorkspaceDeps = parent.rustWorkspaceDeps;
      identityToken = "unchanged-complete-parent";
      extend = _: throw "complete injected package set was extended";
    };
    dataFields = set: builtins.removeAttrs set (["extend"] ++ pkgs.lib.optional (policy == null) "rustWorkspaceDeps");
    outputs = project.mkFlakeOutputs helloFile (injectedArgs
      // {
        pkgsForSystem = _: protectedParent;
        rustWorkspaceDeps = policy;
        packageFor = args:
          assert builtins.attrNames args.pkgs == builtins.attrNames protectedParent;
          assert dataFields args.pkgs == dataFields protectedParent; policyPackage;
      });
  in
    outputs.packages.${system}.default.drvPath == policyPackage.drvPath;
  independentPolicy = parent: policy:
    project.mkFlakeOutputs helloFile {
      nixpkgs.legacyPackages.${system} = parent;
      flake-utils = flakeUtils;
      rustWorkspaceDeps = policy;
      packageFor = args:
      # callPackage must see the new fixed-point policy too. A shallow //
      # would leave its implicit pkgs argument bound to the previous value.
        args.pkgs.callPackage ({pkgs, ...}:
          assert pkgs.rustWorkspaceDeps == policy; policyPackage) {};
    };
  customizations = [
    {overlays = [(_: _: {})];}
    {rustToolchainInputs = {fenix = {};};}
    {rustToolchainProviders = {custom = _: null;};}
  ];
  # Resolver injection can use an otherwise invalid/nonexistent package file.
  # The generic helper must not evaluate repository registration or the file.
  customResolver =
    project.mkFlakeOutputs /nonexistent/standalone-package.nix
    (injectedArgs // {packageFor = _: parentPackages.example-hello-rust;});
  # callPackage also accepts definitions, so this has no repository source path
  # or canonical registration at all, while still receiving the generic Abird
  # package context.
  standalone = project.mkFlakeOutputs ({
    ab,
    runCommand,
  }:
    assert ab ? nixos;
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
  managerConstructorArgs = builtins.functionArgs (import managerFile);
  parentAb = abFor pkgs;
  manager = parentPackages.abird-host-manager;
  directManager = pkgs.callPackage managerFile {ab = parentAb;};
  managerOwnsHostAgentDependency = managerConstructorArgs.abirdHostAgent;
  explicitManager = pkgs.callPackage managerFile {
    ab = parentAb;
    abirdHostAgent = parentPackages.abird-host-agent;
  };
  sourceOnlyManager = pkgs.callPackage managerFile {
    ab = parentAb;
    abirdHostAgent = null;
  };
  directCloudflare = pkgs.callPackage ../../../../pkgs/cloudflare-apps/default.nix {ab = parentAb;};
in
  assert (pkgs.craneLib or null) != null;
  assert children != {};
  # Multiple manifest variants must not silently select the first expectation.
  assert builtins.length existingRoutes == builtins.length (builtins.attrNames allChildren);
  assert builtins.length (builtins.attrNames allChildren) == 13;
  assert builtins.all (path:
    (allWrappers.${path}.inputs.crane.url or null)
    == (
      if requiresCrane path
      then craneUrl
      else null
    )) (builtins.attrNames allChildren);
  # Every child is a mechanical wrapper through the single repository helper;
  # Rust policy lives there rather than being copied into each child source.
  assert builtins.all (
    path: pkgs.lib.hasInfix "lib/project.nix" (builtins.readFile (root + "/${path}"))
  ) (builtins.attrNames allChildren);
  assert pkgs.rustWorkspaceDeps == false;
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
    else throw "child parity: independent default outputs differ from canonical exports for ${path}: actual=${builtins.toJSON (outputPaths defaultOutputs.${path})}; expected=${builtins.toJSON (expectedPaths context.pkgs context.packages path)}")
  smokePaths;
  assert builtins.deepSeq allOutputPaths true;
  assert builtins.deepSeq smokeOutputPaths true;
  assert builtins.all rejectsWrongOutputs [wrongChecks wrongApps wrongShells];
  assert builtins.all (customization:
    fails (project.mkFlakeOutputs helloFile (injectedArgs // customization)))
  customizations;
  assert preservesInjectedPolicy pkgs false;
  assert preservesInjectedPolicy trueParentPkgs true;
  assert preservesInjectedPolicy pkgs null;
  assert preservesInjectedPolicy trueParentPkgs null;
  assert preservesInjectedPolicy (pkgs // {rustWorkspaceDeps = throw "null policy forced parent policy";}) null;
  # A complete injected set cannot be reconfigured in either direction.
  assert fails (policyOutputs trueParentPkgs false).packages.${system}.default.drvPath;
  assert fails (policyOutputs pkgs true).packages.${system}.default.drvPath;
  # Abird's real retained wrapper hardcodes false and must reject a true parent.
  assert fails (wrappers.${helloPath}.outputs (inputsFor wrappers.${helloPath} // {pkgsForSystem = _: trueParentPkgs;})).packages.${system}.default.drvPath;
  # Independently constructed children still extend the fixed point both ways.
  assert (independentPolicy trueParentPkgs false).packages.${system}.default.drvPath == policyPackage.drvPath;
  assert (independentPolicy pkgs true).packages.${system}.default.drvPath == policyPackage.drvPath;
  assert customResolver.packages.${system}.default.drvPath == parentPackages.example-hello-rust.drvPath;
  assert standalone.packages.${system}.default.name == "standalone-child";
  assert (project.mkFlakeOutputs helloFile injectedArgs).packages.${system}.default.drvPath
  == (project.packageFor {
    inherit pkgs;
    packageFile = helloFile;
  }).drvPath;
  # Defaults stay package-owned; explicit derivations and null remain valid
  # overrides. Root and child construction share one bound package context.
  assert managerOwnsHostAgentDependency;
  assert manager.drvPath == directManager.drvPath;
  assert manager.drvPath == explicitManager.drvPath;
  assert builtins.isString sourceOnlyManager.drvPath;
  assert (let
    source = sourceOnlyManager.src.src;
    path = source.origSrc + "/pkgs/tools/abird-host-agent/Cargo.toml";
  in
    source.filter (toString path) "regular" && builtins.pathExists path);
  assert manager.cargoArtifacts.drvPath == directManager.cargoArtifacts.drvPath;
  # The package-owned dependency is present in the manager source closure.
  assert (let
    source = manager.src.src;
    path = source.origSrc + "/pkgs/tools/abird-host-agent/Cargo.toml";
  in
    source.filter (toString path) "regular" && builtins.pathExists path);
  assert !(manager ? memberLayer) && !(manager ? sharedDepsBase);
  assert !(parentPackages.abird-host-agent ? memberLayer);
  assert parentPackages.cloudflare-apps.drvPath == directCloudflare.drvPath;
  assert parentPackages.cloudflare-apps.deploy.drvPath == directCloudflare.deploy.drvPath;
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
