let
  pkg = import ../pkg-helper.nix;
  serviceModuleFactory = import ../service-module.nix;
  packageStack = {
    pkg = pkg;
    mkPkgs = pkgs: let
      packagePkgs =
        pkgs
        // {
          stack = packageStack;
          callPackage = pkgs.lib.callPackageWith packagePkgs;
        };
    in
      packagePkgs;

    # Standalone definitions own their dependency defaults; no manifest lookup.
    # Callers may explicitly inject another builder at the composition boundary.
    packageFor = {
      pkgs,
      packageFile,
    }:
      (packageStack.mkPkgs pkgs).callPackage packageFile {};

    mkFlakeOutputs = packageFile: {
      nixpkgs,
      flake-utils,
      defaultSystem ? builtins.head flake-utils.lib.defaultSystems,
      systems ? flake-utils.lib.defaultSystems,
      overlays ? [],
      crane ? null,
      rustToolchainInputs ? {},
      rustToolchainProviders ? {},
      # Optional repository policy; null preserves the caller's package set.
      # REVIEW (abird post-278a2cba port): the rustWorkspaceDeps seam and the
      # policyPkgs composition contract below are the Abird c50d5c57
      # adaptation; revisit after the rust fabric work lands in both
      # repositories.
      rustWorkspaceDeps ? null,
      # Exact parity/adoption can inject the parent's fully composed package set.
      pkgsForSystem ? null,
      packageFor ? packageStack.packageFor,
      stdFlakeOutputArgs ? _: {},
      # Optional constructor exports share the exact package-system context.
      libExports ? _: {},
      ...
    }: let
      pkgHelper = packageStack.pkg;
      toolchainOverlay =
        (import ../rust/toolchain.nix {
          inputs =
            rustToolchainInputs
            // nixpkgs.lib.optionalAttrs (crane != null) {
              crane = crane;
            };
          providers = rustToolchainProviders;
        }).overlay;
      pkgsFor = system:
        if pkgsForSystem != null
        then pkgsForSystem system
        else if overlays == [] && crane == null && rustToolchainInputs == {} && rustToolchainProviders == {}
        then nixpkgs.legacyPackages.${system}
        else
          import nixpkgs {
            system = system;
            overlays = [toolchainOverlay] ++ overlays;
          };
      mkOutputs = pkgsInput: let
        # Complete injected package sets are immutable composition contracts.
        # Only independent construction may extend the fixed point: a shallow
        # // leaves callPackage bound to old `pkgs` and loses the policy.
        policyPkgs =
          if rustWorkspaceDeps == null || (pkgsInput.rustWorkspaceDeps or null) == rustWorkspaceDeps
          then pkgsInput
          else if pkgsForSystem != null
          then throw "mkFlakeOutputs: rustWorkspaceDeps disagrees with pkgsForSystem's complete package set; configure rustWorkspaceDeps in pkgsForSystem instead"
          else pkgsInput.extend (_final: _prev: {inherit rustWorkspaceDeps;});
        pkgs = packageStack.mkPkgs policyPkgs;
        drv = packageFor {
          pkgs = policyPkgs;
          packageFile = packageFile;
        };
        flakeOutputs = pkgHelper.mkStdFlakeOutputs ({
            pkgs = pkgs;
            build = drv;
          }
          // stdFlakeOutputArgs {
            pkgs = pkgs;
            build = drv;
            pkgHelper = pkgHelper;
          });
        nixosModules = pkgHelper.mkNixosModuleAttrs {
          build = drv;
        };
      in
        # Validate even when an injected packageFor ignores its pkgs argument.
        builtins.seq policyPkgs {
          flakeOutputs = flakeOutputs;
          nixosModules = nixosModules;
          library = libExports {
            pkgs = policyPkgs;
            build = drv;
            pkgHelper = pkgHelper;
          };
        };
      # Share one lazy output record per system, including the module-export
      # system when it is not in systems. Duplicate keys keep the first thunk.
      outputsBySystem = builtins.listToAttrs (map (system: {
        name = system;
        value = mkOutputs (pkgsFor system);
      }) (systems ++ [defaultSystem]));
      defaultOutputs = outputsBySystem.${defaultSystem};
    in
      if pkgsForSystem != null && (overlays != [] || rustToolchainInputs != {} || rustToolchainProviders != {})
      then throw "mkFlakeOutputs: pkgsForSystem supplies the complete package set; overlays, rustToolchainInputs and rustToolchainProviders must be configured there instead"
      else
        flake-utils.lib.eachSystem systems (system: let
          output = outputsBySystem.${system};
        in
          if !builtins.isAttrs output.library
          then throw "mkFlakeOutputs: libExports must return an attribute set"
          else
            # Never touch the `nixpkgs` input here: a complete injected package
            # set (pkgsForSystem) must evaluate without it, and `optionalAttrs`
            # would force `nixpkgs.lib` even when no library is exported.
            output.flakeOutputs
            // (
              if output.library == {}
              then {}
              else {lib = output.library;}
            ))
        // (
          if defaultOutputs.nixosModules == {}
          then {}
          else {
            nixosModules = defaultOutputs.nixosModules;
          }
        );

    stackName = "package";
    org = "package";
    env = "standalone";
    defaultMailDomain = "invalid.invalid";
    publicDomain = "invalid.invalid";
    internalDomain = "package.internal";
    defaultNginxSecretsBasePath = /nonexistent/lib-flake/nginx-secrets;
    defaultNginxSecretsBase = /nonexistent/lib-flake/nginx-secrets;
    defaultCaCertFile = null;
    defaultCaCertAgeFile = /nonexistent/lib-flake/client-secrets/ca.crt.age;
    defaultCaCertHostPath = "/etc/ssl/certs/package-ca.crt";
    defaultCaCertContainerPath = "/run/secrets/package-ca.crt";
    defaultCaCertificate = {
      file = "/etc/ssl/certs/package-ca.crt";
      sourceHashFile = null;
      mountPath = "/run/secrets/package-ca.crt";
    };
    srv = serviceModuleFactory.mkServiceLib {
      stackName = "package";
      defaultUser = "root";
      defaultClientSecretsBasePath = /nonexistent/lib-flake/client-secrets;
      defaultClientIdentitySuffix = "invalid.invalid";
      defaultExtServiceIdentitySuffix = "invalid.invalid";
      defaultServiceIdentitySuffix = "invalid.invalid";
      defaultPostgresUrl = "";
      defaultPostgresCaCertPath = "";
      defaultNatsUrl = "";
      defaultNatsCaCertPath = "";
    };
  };
in
  packageStack
