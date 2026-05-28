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
    registry = {};
    serviceRegistry = {};
    defaultNginxSecretsBasePath = /nonexistent/lib-flake/nginx-secrets;
    defaultNginxSecretsBase = /nonexistent/lib-flake/nginx-secrets;
    defaultCaCertFile = null;
    defaultCaCertAgeFile = /nonexistent/lib-flake/secrets/ca.crt.age;
    defaultCaCertHostPath = "/etc/ssl/certs/package-ca.crt";
    defaultCaCertContainerPath = "/run/secrets/package-ca.crt";
    defaultCaBundleHostPath = "/etc/ssl/certs/package-ca-bundle.crt";
    defaultCaBundleContainerPath = "/run/secrets/package-ca-bundle.crt";
    defaultCaCertificate = {
      file = "/etc/ssl/certs/package-ca.crt";
      sourceHashFile = null;
      mountPath = "/run/secrets/package-ca.crt";
    };
    defaultCaBundleCertificate = {
      file = "/etc/ssl/certs/package-ca-bundle.crt";
      sourceHashFile = null;
      mountPath = "/run/secrets/package-ca-bundle.crt";
    };
    secrets = rec {
      base = /nonexistent/lib-flake/secrets;
      services = /nonexistent/lib-flake/client-secrets;
      service = name: services + "/${name}";
      ext = provider: base + "/ext/${provider}";
      ca = base;
      acme = base + "/acme";
      nats = null;
      postgres = null;
      vmstack = null;
      nginx = /nonexistent/lib-flake/nginx-secrets;
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
