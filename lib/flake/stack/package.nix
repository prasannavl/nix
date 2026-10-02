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
      # Exact parity/adoption can inject the parent's fully composed package set.
      pkgsForSystem ? null,
      packageFor ? packageStack.packageFor,
      stdFlakeOutputArgs ? _: {},
      ...
    }: let
      pkgHelper = packageStack.pkg;
      toolchainOverlay =
        (import ../rust-toolchain.nix {
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
        pkgs = packageStack.mkPkgs pkgsInput;
        drv = packageFor {
          pkgs = pkgsInput;
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
      in {
        flakeOutputs = flakeOutputs;
        nixosModules = nixosModules;
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
        flake-utils.lib.eachSystem systems (system:
          outputsBySystem.${system}.flakeOutputs)
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
