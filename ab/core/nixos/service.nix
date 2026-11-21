{
  mkCore,
  projectRoot ? null,
  treefmtConfig ? null,
}: let
  inferSourcePath = args: let
    pos =
      builtins.foldl'
      (acc: attrName:
        if acc != null
        then acc
        else builtins.unsafeGetAttrPos attrName args)
      null
      (builtins.attrNames args);
  in
    if pos == null
    then null
    else /. + pos.file;

  evalServicePart = field: fallback: service:
    if builtins.hasAttr field service
    then (builtins.getAttr field service) service
    else fallback;

  composeServices = services: {
    capabilities =
      builtins.foldl'
      (acc: service: acc // (evalServicePart "capabilities" {} service))
      {}
      services;

    defaults =
      builtins.foldl'
      (acc: service: acc // (evalServicePart "defaults" {} service))
      {}
      services;

    extraOptions = lib:
      builtins.foldl'
      (acc: service: acc // (evalServicePart "extraOptions" (_: {}) service lib))
      {}
      services;

    environment = cfg:
      builtins.foldl'
      (acc: service: acc // (evalServicePart "environment" (_: {}) service cfg))
      {}
      services;

    unitConfig = lib: cfg:
      builtins.foldl' (
        acc: service: let
          next = evalServicePart "unitConfig" (_: {}) service cfg;
        in {
          after = lib.unique (acc.after ++ (next.after or []));
          before = lib.unique (acc.before ++ (next.before or []));
          wants = lib.unique (acc.wants ++ (next.wants or []));
          requires = lib.unique (acc.requires ++ (next.requires or []));
          wantedBy = lib.unique (acc.wantedBy ++ (next.wantedBy or []));
        }
      ) {
        after = [];
        before = [];
        wants = [];
        requires = [];
        wantedBy = [];
      }
      services;

    extraServiceConfig = cfg:
      builtins.foldl'
      (acc: service: acc // (evalServicePart "extraServiceConfig" (_: {}) service cfg))
      {}
      services;

    extraConfigs = cfg:
      map (service: evalServicePart "extraConfig" (_: {}) service cfg) services;

    sourcePath =
      if services == []
      then null
      else (builtins.elemAt services 0).__sourcePath or null;
  };

  applyServiceDefaults = resolved: service:
    service
    // (
      if !(service ? envPrefix) && resolved ? envPrefix && resolved.envPrefix != null
      then {envPrefix = resolved.envPrefix;}
      else {}
    )
    // (
      if !(service ? serviceName) && resolved ? serviceName && resolved.serviceName != null
      then {serviceName = resolved.serviceName;}
      else {}
    )
    // (
      if service ? __applyDefaults
      then service.__applyDefaults resolved
      else {}
    );

  resolveUnitReference = dep:
    if builtins.match ".*\\.[A-Za-z0-9_-]+$" dep != null
    then dep
    else "${dep}.service";

  mkUnitWiringOptions = {
    lib,
    descriptionSuffix,
  }: {
    wants = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional ${descriptionSuffix} this service wants.";
    };

    requires = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional ${descriptionSuffix} this service requires.";
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional ${descriptionSuffix} this service should start after.";
    };

    before = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional ${descriptionSuffix} this service should start before.";
    };

    wantedBy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional ${descriptionSuffix} that should want this service.";
    };
  };

  mkResolvedServiceSpec = {
    lib,
    package,
    name,
    envPrefix,
    serviceName,
    serviceDescription,
    packageDescription,
    extraOptions,
    services,
    restart,
    kindLabel,
    constructorName,
  }: let
    resolvedName =
      if name != null
      then name
      else package.pname or (throw "ab.nixos.${constructorName}: name is required when the package has no pname");
    resolvedServiceDescription =
      if serviceDescription != null
      then serviceDescription
      else resolvedName;
    resolvedPackageDescription =
      if packageDescription != null
      then packageDescription
      else "The ${resolvedName} package to run as a ${kindLabel}.";
    resolvedServiceName =
      if serviceName != null
      then serviceName
      else resolvedName;
    resolvedServices =
      map (
        service:
          applyServiceDefaults {
            __resolvedName = resolvedName;
            inherit envPrefix;
            serviceName = resolvedServiceName;
          }
          service
      )
      services;
    composedServices = composeServices resolvedServices;
    resolvedExtraOptions = composedServices.extraOptions lib // extraOptions lib;
    hasPort =
      builtins.hasAttr "port" resolvedExtraOptions
      || builtins.any (service: service.__hasPort or false) resolvedServices;
  in {
    defaultPackage = package;
    inherit
      resolvedName
      resolvedServiceDescription
      resolvedPackageDescription
      resolvedServiceName
      resolvedServices
      composedServices
      resolvedExtraOptions
      hasPort
      restart
      ;
    defaultPackageText = lib.literalExpression "package";
  };

  mkBoundModuleFactory = {
    args,
    sourcePath,
    moduleFn,
    constructor,
  }: {
    __moduleArgs = args;
    __moduleFn = moduleFn;
    __moduleConstructor = constructor;
    __moduleSourcePath = sourcePath;

    __boundModuleFactory = build: {specialArgs, ...} @ moduleArgs: let
      resolvedSourcePath =
        if sourcePath != null
        then sourcePath
        else if build ? passthru && build.passthru ? sourcePath
        then build.passthru.sourcePath
        else if build ? src
        then build.src + "/default.nix"
        else throw "ab.nixos.${constructor}: sourcePath is required when package is omitted and the build has no sourcePath/src";
      targetPkgs = specialArgs.abNixosPkgs or null;
      package =
        if targetPkgs == null
        then build
        else let
          targetAb = mkCore {
            pkgs = targetPkgs;
            inherit projectRoot treefmtConfig;
          };
        in
          targetPkgs.callPackage resolvedSourcePath {
            pkgs = targetPkgs;
            ab = targetAb;
          };
      currentModuleFactory = package.passthru.nixosModule or {};
      currentModuleFn =
        if builtins.isAttrs currentModuleFactory && currentModuleFactory ? __moduleFn
        then currentModuleFactory.__moduleFn
        else moduleFn;
      currentModuleArgs =
        if builtins.isAttrs currentModuleFactory && currentModuleFactory ? __moduleArgs
        then currentModuleFactory.__moduleArgs
        else args;
    in
      (currentModuleFn (
        currentModuleArgs
        // {
          package = package;
          sourcePath = resolvedSourcePath;
        }
      ))
      moduleArgs;
  };

  packageModule = {
    module,
    args ? {},
    packageArgs ? {},
    sourcePath ? null,
  }: {
    __moduleArgs = args;
    __moduleFn = module;
    __moduleConstructor = "packageModule";
    __moduleSourcePath = sourcePath;

    __boundModuleFactory = build: {specialArgs, ...}: let
      resolvedSourcePath =
        if sourcePath != null
        then sourcePath
        else if build ? passthru && build.passthru ? sourcePath
        then build.passthru.sourcePath
        else if build ? src
        then build.src + "/default.nix"
        else throw "ab.nixos.packageModule: sourcePath is required when the build has no sourcePath/src";
      targetPkgs = specialArgs.abNixosPkgs or null;
      package =
        if targetPkgs == null
        then build
        else let
          targetAb = mkCore {
            pkgs = targetPkgs;
            inherit projectRoot treefmtConfig;
          };
        in
          targetPkgs.callPackage resolvedSourcePath ({
              pkgs = targetPkgs;
              ab = targetAb;
            }
            // packageArgs);
    in {
      imports = [
        (module (
          args
          // {
            inherit package;
          }
        ))
      ];
    };
  };

  resolvePolicy = {
    policy,
    capabilities,
  }: {
    identity =
      if capabilities ? identity && policy != null && policy ? identityFor
      then policy.identityFor capabilities.identity.serviceName
      else null;
    nats =
      if capabilities ? nats && policy != null && policy ? nats
      then policy.nats
      else null;
    postgres =
      if capabilities ? postgres && policy != null && policy ? postgres
      then policy.postgres
      else null;
    requireLocalNats = capabilities.nats.requireLocalNats or false;
  };

  policyList = binding: field:
    if binding == null
    then []
    else binding.${field} or [];

  policyDefaults = {
    lib,
    resolved,
  }:
    (lib.optionalAttrs (resolved.identity != null) {
      serviceCertPath = lib.mkDefault resolved.identity.certRuntimePath;
      serviceKeyPath = lib.mkDefault resolved.identity.keyRuntimePath;
    })
    // (lib.optionalAttrs (resolved.nats != null) {
      natsUrl = lib.mkDefault resolved.nats.url;
      natsCaCertPath = lib.mkDefault resolved.nats.caCertPath;
    })
    // (lib.optionalAttrs (resolved.postgres != null) {
      postgresUrl = lib.mkDefault resolved.postgres.url;
      postgresCaCertPath = lib.mkDefault resolved.postgres.caCertPath;
    });

  policyAgeSecrets = resolved:
    if resolved.identity == null
    then {}
    else resolved.identity.ageSecrets or {};

  systemService = args @ {
    package ? null,
    sourcePath ? null,
    name ? null,
    envPrefix ? null,
    serviceName ? null,
    serviceDescription ? null,
    packageDescription ? null,
    extraOptions ? (_: {}),
    environment ? (_: {}),
    extraServiceConfig ? (_: {}),
    services ? [],
    wantedBy ? ["multi-user.target"],
    after ? ["network.target"],
    before ? [],
    wants ? [],
    requires ? [],
    restart ? "on-failure",
  }:
    if package == null
    then
      mkBoundModuleFactory {
        inherit args sourcePath;
        moduleFn = systemService;
        constructor = "systemService";
      }
    else
      {
        config,
        lib,
        ...
      } @ moduleArgs: let
        spec = mkResolvedServiceSpec {
          inherit
            envPrefix
            extraOptions
            lib
            name
            package
            packageDescription
            serviceDescription
            serviceName
            services
            restart
            ;
          kindLabel = "service";
          constructorName = "systemService";
        };
        cfg = config.services.${spec.resolvedName};
        resolvedPolicy = resolvePolicy {
          policy = moduleArgs.abNixosPolicy or null;
          capabilities = spec.composedServices.capabilities;
        };
        policyAfter =
          policyList resolvedPolicy.nats "after"
          ++ policyList resolvedPolicy.postgres "after";
        policyWants =
          lib.optionals resolvedPolicy.requireLocalNats
          (policyList resolvedPolicy.nats "after");
        policyRequires = policyWants;
        partUnitConfig = spec.composedServices.unitConfig lib cfg;
        resolvedAfter = lib.unique (after ++ policyAfter ++ cfg.after ++ partUnitConfig.after);
        resolvedBefore = lib.unique (before ++ cfg.before ++ partUnitConfig.before);
        resolvedWants = lib.unique (wants ++ policyWants ++ cfg.wants ++ partUnitConfig.wants);
        resolvedRequires = lib.unique (requires ++ policyRequires ++ cfg.requires ++ partUnitConfig.requires);
        resolvedWantedBy = lib.unique (wantedBy ++ cfg.wantedBy ++ partUnitConfig.wantedBy);
      in {
        imports = [./registry.nix];

        options.services.${spec.resolvedName} =
          {
            enable = lib.mkEnableOption "${spec.resolvedName} service";

            package = lib.mkOption {
              type = lib.types.package;
              default = spec.defaultPackage;
              defaultText = spec.defaultPackageText;
              description = spec.resolvedPackageDescription;
            };
          }
          // (mkUnitWiringOptions {
            inherit lib;
            descriptionSuffix = "systemd units or targets";
          })
          // spec.resolvedExtraOptions;

        config = lib.mkMerge [
          {
            services.${spec.resolvedName} = policyDefaults {
              inherit lib;
              resolved = resolvedPolicy;
            };
          }
          (lib.mkIf cfg.enable (lib.mkMerge (
            [
              {
                systemd.services.${spec.resolvedName} = {
                  description = spec.resolvedServiceDescription;
                  wantedBy = resolvedWantedBy;
                  stopIfChanged = true;
                  after = resolvedAfter;
                  before = resolvedBefore;
                  wants = resolvedWants;
                  unitConfig.Requires = resolvedRequires;
                  environment = spec.composedServices.environment cfg // environment cfg;
                  serviceConfig =
                    {
                      ExecStart = lib.getExe cfg.package;
                      Restart = restart;
                    }
                    // spec.composedServices.extraServiceConfig cfg
                    // extraServiceConfig cfg;
                };

                _ab.nixos.registeredPorts = lib.optional spec.hasPort {
                  name = spec.resolvedName;
                  port = cfg.port;
                };

                _ab.nixos.registeredUnits = [
                  {
                    name = spec.resolvedName;
                    scope = "system";
                    user = null;
                    unit = "${spec.resolvedName}.service";
                  }
                ];
              }
            ]
            ++ lib.optional (policyAgeSecrets resolvedPolicy != {}) {
              age.secrets = policyAgeSecrets resolvedPolicy;
            }
            ++ spec.composedServices.extraConfigs cfg
          )))
        ];
      };

  userService = args @ {
    package ? null,
    sourcePath ? null,
    user,
    name ? null,
    envPrefix ? null,
    serviceName ? null,
    serviceDescription ? null,
    packageDescription ? null,
    extraOptions ? (_: {}),
    environment ? (_: {}),
    extraServiceConfig ? (_: {}),
    services ? [],
    wantedBy ? [],
    after ? [],
    before ? [],
    wants ? [],
    requires ? [],
    restart ? "on-failure",
  }:
    if package == null
    then
      mkBoundModuleFactory {
        inherit args sourcePath;
        moduleFn = userService;
        constructor = "userService";
      }
    else
      {
        config,
        lib,
        ...
      } @ moduleArgs: let
        spec = mkResolvedServiceSpec {
          inherit
            envPrefix
            extraOptions
            lib
            name
            package
            packageDescription
            serviceDescription
            serviceName
            services
            restart
            ;
          kindLabel = "user service";
          constructorName = "userService";
        };
        cfg = config.user-services.${user}.${spec.resolvedName};
        resolvedPolicy = resolvePolicy {
          policy = moduleArgs.abNixosPolicy or null;
          capabilities = spec.composedServices.capabilities;
        };
        policyAfter =
          policyList resolvedPolicy.nats "after"
          ++ policyList resolvedPolicy.postgres "after";
        policyWants =
          lib.optionals resolvedPolicy.requireLocalNats
          (policyList resolvedPolicy.nats "after");
        policyRequires = policyWants;
        partUnitConfig = spec.composedServices.unitConfig lib cfg;
        resolvedAfter = lib.unique (map resolveUnitReference (after ++ policyAfter ++ cfg.after ++ partUnitConfig.after));
        resolvedBefore = lib.unique (map resolveUnitReference (before ++ cfg.before ++ partUnitConfig.before));
        resolvedWants = lib.unique (map resolveUnitReference (wants ++ policyWants ++ cfg.wants ++ partUnitConfig.wants));
        resolvedRequires = lib.unique (map resolveUnitReference (requires ++ policyRequires ++ cfg.requires ++ partUnitConfig.requires));
        resolvedWantedBy = lib.unique (map resolveUnitReference (wantedBy ++ cfg.wantedBy ++ partUnitConfig.wantedBy));
        unitLabel = cfg.unitName;
      in {
        imports = [./registry.nix];

        options.user-services.${user}.${spec.resolvedName} =
          {
            enable = lib.mkEnableOption "${spec.resolvedName} user service";

            package = lib.mkOption {
              type = lib.types.package;
              default = spec.defaultPackage;
              defaultText = spec.defaultPackageText;
              description = spec.resolvedPackageDescription;
            };

            unitName = lib.mkOption {
              type = lib.types.str;
              default = "${user}-${spec.resolvedName}";
              description = "Generated systemd --user unit name without the .service suffix.";
            };
          }
          // (mkUnitWiringOptions {
            inherit lib;
            descriptionSuffix = "systemd --user units or targets";
          })
          // spec.resolvedExtraOptions;

        config = lib.mkMerge [
          {
            user-services.${user}.${spec.resolvedName} = policyDefaults {
              inherit lib;
              resolved = resolvedPolicy;
            };
          }
          (lib.mkIf cfg.enable (lib.mkMerge (
            [
              {
                systemd.user.services.${unitLabel} = {
                  description = spec.resolvedServiceDescription;
                  wants = resolvedWants;
                  after = resolvedAfter;
                  before = resolvedBefore;
                  wantedBy = resolvedWantedBy;
                  unitConfig = {
                    ConditionUser = user;
                    Requires = resolvedRequires;
                  };
                  environment = spec.composedServices.environment cfg // environment cfg;
                  serviceConfig =
                    {
                      ExecStart = lib.getExe cfg.package;
                      Restart = restart;
                    }
                    // spec.composedServices.extraServiceConfig cfg
                    // extraServiceConfig cfg;
                };

                _ab.nixos.registeredPorts = lib.optional spec.hasPort {
                  name = "${user}.${spec.resolvedName}";
                  port = cfg.port;
                };

                _ab.nixos.registeredUnits = [
                  {
                    name = "${user}:${spec.resolvedName}";
                    scope = "user";
                    inherit user;
                    unit = "${unitLabel}.service";
                  }
                ];
              }
            ]
            ++ lib.optional (policyAgeSecrets resolvedPolicy != {}) {
              age.secrets = policyAgeSecrets resolvedPolicy;
            }
            ++ spec.composedServices.extraConfigs cfg
          )))
        ];
      };

  service = args @ {
    package ? null,
    sourcePath ? null,
    user ? null,
    ...
  }:
    if package == null
    then
      mkBoundModuleFactory {
        inherit args sourcePath;
        moduleFn = service;
        constructor = "service";
      }
    else
      moduleArgs: let
        resolvedUser =
          if user != null
          then user
          else moduleArgs.abNixosUser or null;
        constructorArgs = builtins.removeAttrs args ["user"];
      in
        if resolvedUser == null || resolvedUser == "root"
        then (systemService constructorArgs) moduleArgs
        else (userService (constructorArgs // {user = resolvedUser;})) moduleArgs;

  http = args @ {
    bindEnvVar ? null,
    listenAddressDescription ? "IP address for the listener.",
    portDescription ? "TCP port for the listener.",
    defaultListenAddress ? "0.0.0.0",
    defaultPort,
  }: {
    __sourcePath = inferSourcePath args;
    __hasPort = true;

    extraOptions = _: lib: {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = defaultListenAddress;
        description = listenAddressDescription;
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = portDescription;
      };
    };

    defaults = _: {
      listenAddress = defaultListenAddress;
      port = defaultPort;
    };

    environment = _serviceSpec: cfg:
      if bindEnvVar == null
      then {}
      else {
        "${bindEnvVar}" = "${cfg.listenAddress}:${toString cfg.port}";
      };
  };

  identity = args @ {serviceName ? null}: {
    __sourcePath = inferSourcePath args;
    __applyDefaults = resolved: {
      serviceName =
        if serviceName != null
        then serviceName
        else resolved.serviceName;
    };

    capabilities = serviceSpec: {
      identity.serviceName = serviceSpec.serviceName;
    };

    extraOptions = _serviceSpec: lib: {
      serviceCertPath = lib.mkOption {
        type = lib.types.str;
        description = "mTLS client certificate path supplied by deployment policy.";
      };

      serviceKeyPath = lib.mkOption {
        type = lib.types.str;
        description = "mTLS client key path supplied by deployment policy.";
      };
    };
  };

  postgresClient = args @ {
    postgresUrlDescription ? "PostgreSQL connection URL.",
    postgresCaCertPathDescription ? "CA certificate path for PostgreSQL TLS.",
    after ? [],
    before ? [],
    wants ? [],
    requires ? [],
    wantedBy ? [],
  }: {
    __sourcePath = inferSourcePath args;
    capabilities = _: {postgres = {};};

    extraOptions = _serviceSpec: lib: {
      postgresUrl = lib.mkOption {
        type = lib.types.str;
        description = postgresUrlDescription;
      };

      postgresCaCertPath = lib.mkOption {
        type = lib.types.str;
        description = postgresCaCertPathDescription;
      };
    };

    environment = serviceSpec: cfg: {
      "${serviceSpec.envPrefix}_POSTGRES_URL" = cfg.postgresUrl;
      "${serviceSpec.envPrefix}_POSTGRES_CA_CERT_PATH" = cfg.postgresCaCertPath;
      "${serviceSpec.envPrefix}_POSTGRES_CLIENT_CERT_PATH" = cfg.serviceCertPath;
      "${serviceSpec.envPrefix}_POSTGRES_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
    };

    unitConfig = _serviceSpec: _cfg: {
      inherit
        after
        before
        wants
        requires
        wantedBy
        ;
    };
  };

  natsClient = args @ {
    natsUrlDescription ? "NATS URL.",
    natsCaCertPathDescription ? "CA certificate path for NATS mTLS.",
    after ? [],
    before ? [],
    wants ? [],
    requires ? [],
    requireLocalNats ? false,
    wantedBy ? [],
  }: {
    __sourcePath = inferSourcePath args;
    capabilities = _: {
      nats = {
        inherit requireLocalNats;
      };
    };

    extraOptions = _serviceSpec: lib: {
      natsUrl = lib.mkOption {
        type = lib.types.str;
        description = natsUrlDescription;
      };

      natsCaCertPath = lib.mkOption {
        type = lib.types.str;
        description = natsCaCertPathDescription;
      };
    };

    environment = serviceSpec: cfg: {
      "${serviceSpec.envPrefix}_NATS_URL" = cfg.natsUrl;
      "${serviceSpec.envPrefix}_NATS_CA_CERT_PATH" = cfg.natsCaCertPath;
      "${serviceSpec.envPrefix}_NATS_CLIENT_CERT_PATH" = cfg.serviceCertPath;
      "${serviceSpec.envPrefix}_NATS_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
    };

    unitConfig = _serviceSpec: _cfg: {
      inherit
        after
        before
        wants
        requires
        wantedBy
        ;
    };
  };

  tcpService = {
    package ? null,
    user ? null,
    name ? null,
    bindEnvVar,
    serviceDescription ? null,
    packageDescription ? null,
    listenAddressDescription ? null,
    portDescription ? null,
    defaultListenAddress ? "0.0.0.0",
    defaultPort,
    extraOptions ? (_: {}),
    environment ? (_: {}),
    extraServiceConfig ? (_: {}),
    wantedBy ? ["multi-user.target"],
    after ? ["network.target"],
    before ? [],
    wants ? [],
    requires ? [],
    restart ? "on-failure",
  }:
    service {
      inherit
        package
        user
        name
        serviceDescription
        packageDescription
        extraServiceConfig
        wantedBy
        after
        before
        wants
        requires
        restart
        extraOptions
        environment
        ;
      services = [
        (http {
          inherit
            bindEnvVar
            defaultListenAddress
            defaultPort
            listenAddressDescription
            portDescription
            ;
        })
      ];
    };
in {
  inherit
    service
    systemService
    userService
    tcpService
    http
    identity
    natsClient
    packageModule
    postgresClient
    composeServices
    ;
  registryModule = ./registry.nix;
}
