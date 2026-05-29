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

    mkFlakeOutputs = packageFile: {
      nixpkgs,
      flake-utils,
      defaultSystem ? builtins.head flake-utils.lib.defaultSystems,
      systems ? flake-utils.lib.defaultSystems,
      stdFlakeOutputArgs ? _: {},
      ...
    }: let
      pkgHelper = packageStack.pkg;
      mkOutputs = pkgsInput: let
        pkgs = packageStack.mkPkgs pkgsInput;
        drv = pkgs.callPackage packageFile {};
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
      defaultOutputs = mkOutputs nixpkgs.legacyPackages.${defaultSystem};
    in
      flake-utils.lib.eachSystem systems (system:
        (mkOutputs nixpkgs.legacyPackages.${system}).flakeOutputs)
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
