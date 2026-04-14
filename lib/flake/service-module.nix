rec {
  mkServiceLib = {
    defaultUser ? "root",
    defaultClientRuntimeBasePath ? "/run/agenix",
    defaultClientSecretsBasePath,
    defaultClientIdentitySuffix ? null,
    defaultServiceIdentitySuffix,
    defaultClientSecretOwner ? "root",
    defaultClientSecretGroup ? "root",
    defaultClientSecretMode ? "0400",
    defaultServiceSecretOwner ? "root",
    defaultServiceSecretGroup ? "root",
    defaultServiceSecretMode ? "0400",
    defaultPostgresUrl,
    defaultPostgresCaCertPath,
    defaultPostgresAfter ? [],
    defaultNatsUrl,
    defaultNatsCaCertPath,
    defaultNatsAfter ? [],
  }: let
    trackedPath = path: name:
      if builtins.pathExists path
      then
        builtins.path {
          inherit path name;
        }
      else null;
  in rec {
    inherit
      defaultUser
      defaultClientRuntimeBasePath
      defaultClientSecretsBasePath
      defaultClientIdentitySuffix
      defaultServiceIdentitySuffix
      defaultClientSecretOwner
      defaultClientSecretGroup
      defaultClientSecretMode
      defaultServiceSecretOwner
      defaultServiceSecretGroup
      defaultServiceSecretMode
      defaultPostgresUrl
      defaultPostgresCaCertPath
      defaultPostgresAfter
      defaultNatsUrl
      defaultNatsCaCertPath
      defaultNatsAfter
      ;

    ########################################
    # Core Exported Module Entry Points
    ########################################

    mkServicesModule = args: let
      resolvedUser =
        if args ? user && args.user != null
        then args.user
        else defaultUser;
    in
      if resolvedUser == "root"
      then mkModule (builtins.removeAttrs args ["user"])
      else mkUserServicesModule (args // {user = resolvedUser;});

    mkSystemServicesModule = mkModule;

    mkModule = args @ {
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
          moduleFn = mkModule;
          constructor = "mkModule";
        }
      else
        {
          config,
          lib,
          ...
        }: let
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
            constructorName = "mkModule";
          };
          cfg = config.services.${spec.resolvedName};
          partUnitConfig = spec.composedServices.unitConfig lib cfg;
          resolvedAfter = lib.unique (after ++ cfg.after ++ partUnitConfig.after);
          resolvedBefore = lib.unique (before ++ cfg.before ++ partUnitConfig.before);
          resolvedWants = lib.unique (wants ++ cfg.wants ++ partUnitConfig.wants);
          resolvedRequires = lib.unique (requires ++ cfg.requires ++ partUnitConfig.requires);
          resolvedWantedBy = lib.unique (wantedBy ++ cfg.wantedBy ++ partUnitConfig.wantedBy);
        in {
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
            // spec.composedServices.extraOptions lib
            // extraOptions lib;

          config = lib.mkIf cfg.enable (lib.mkMerge ([
              {
                systemd.services.${spec.resolvedName} = {
                  description = spec.resolvedServiceDescription;
                  wantedBy = resolvedWantedBy;
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
                _serviceModule.registeredPorts = lib.optional spec.hasPort {
                  name = spec.resolvedName;
                  port = cfg.port;
                };
              }
            ]
            ++ spec.composedServices.extraConfigs cfg));
        };

    mkUserServicesModule = args @ {
      package ? null,
      sourcePath ? null,
      user ? null,
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
          moduleFn = mkUserServicesModule;
          constructor = "mkUserServicesModule";
        }
      else
        {
          config,
          lib,
          ...
        }: let
          resolvedUser =
            if user != null
            then user
            else throw "service-module.mkUserServicesModule: `user` is required";
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
            constructorName = "mkUserServicesModule";
          };
          cfg = config.userServices.${resolvedUser}.${spec.resolvedName};
          partUnitConfig = spec.composedServices.unitConfig lib cfg;
          resolvedAfter = lib.unique (map resolveUnitReference (after ++ cfg.after ++ partUnitConfig.after));
          resolvedBefore = lib.unique (map resolveUnitReference (before ++ cfg.before ++ partUnitConfig.before));
          resolvedWants = lib.unique (map resolveUnitReference (wants ++ cfg.wants ++ partUnitConfig.wants));
          resolvedRequires = lib.unique (map resolveUnitReference (requires ++ cfg.requires ++ partUnitConfig.requires));
          resolvedWantedBy = lib.unique (map resolveUnitReference (wantedBy ++ cfg.wantedBy ++ partUnitConfig.wantedBy));
          unitLabel = cfg.unitName;
          unitFile = "${unitLabel}.service";
          instanceName = "${resolvedUser}-${spec.resolvedName}";
          serviceEnvironment = spec.composedServices.environment cfg // environment cfg;
          serviceConfig =
            {
              ExecStart = lib.getExe cfg.package;
              Restart = restart;
            }
            // spec.composedServices.extraServiceConfig cfg
            // extraServiceConfig cfg;
          stampPayload = {
            kind = "user-service";
            user = resolvedUser;
            serviceName = spec.resolvedName;
            unitName = unitLabel;
            package = cfg.package;
            wants = resolvedWants;
            requires = resolvedRequires;
            after = resolvedAfter;
            wantedBy = resolvedWantedBy;
            environment = serviceEnvironment;
            serviceConfig = serviceConfig;
          };
        in {
          options.userServices.${resolvedUser}.${spec.resolvedName} =
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
                default = "${resolvedUser}-${spec.resolvedName}";
                description = "Generated systemd --user unit name without the .service suffix.";
              };
            }
            // (mkUnitWiringOptions {
              inherit lib;
              descriptionSuffix = "systemd --user units or targets";
            })
            // spec.composedServices.extraOptions lib
            // extraOptions lib;

          config = lib.mkIf cfg.enable (lib.mkMerge ([
              {
                systemd.user.services.${unitLabel} = {
                  description = spec.resolvedServiceDescription;
                  wants = resolvedWants;
                  after = resolvedAfter;
                  before = resolvedBefore;
                  wantedBy = resolvedWantedBy;
                  unitConfig = {
                    ConditionUser = resolvedUser;
                    Requires = resolvedRequires;
                  };
                  environment = serviceEnvironment;
                  inherit serviceConfig;
                };

                services.systemdUserManager.instances.${instanceName} = {
                  user = resolvedUser;
                  unit = unitFile;
                  restartTriggers = [
                    cfg.package
                  ];
                  inherit stampPayload;
                };

                _serviceModule.registeredPorts = lib.optional spec.hasPort {
                  name = "${resolvedUser}.${spec.resolvedName}";
                  port = cfg.port;
                };
              }
            ]
            ++ spec.composedServices.extraConfigs cfg));
        };

    mkTcpServiceModule = {
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
      mkServicesModule {
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
          ;
        services = [
          (mkHttpService {
            inherit
              bindEnvVar
              defaultListenAddress
              defaultPort
              listenAddressDescription
              portDescription
              ;
          })
        ];
        inherit
          extraOptions
          environment
          ;
      };

    portCheckModule = {
      config,
      lib,
      ...
    }: let
      registeredPorts = config._serviceModule.registeredPorts;
      portGroups = builtins.groupBy (entry: toString entry.port) registeredPorts;
      conflicts = lib.filterAttrs (_: entries: builtins.length entries > 1) portGroups;
      conflictMessages =
        lib.mapAttrsToList (
          port: entries:
            "Port ${port} is used by multiple enabled services: ${lib.concatMapStringsSep ", " (e: e.name) entries}. "
            + "Assign distinct ports to avoid bind conflicts."
        )
        conflicts;
    in {
      options._serviceModule.registeredPorts = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        internal = true;
        description = "Registry of TCP ports claimed by service modules for clash detection.";
      };

      config.assertions =
        map (msg: {
          assertion = false;
          message = msg;
        })
        conflictMessages;
    };

    ########################################
    # Common Helpers And Abstractions
    ########################################

    # This is only a convenience fallback for deriving a package-local source
    # path from the call site. It relies on `unsafeGetAttrPos`, so callers can
    # always pass `sourcePath` explicitly when they need stricter behavior.
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
      defaults =
        builtins.foldl' (acc: service: acc // (evalServicePart "defaults" (_: {}) service)) {} services;
      extraOptions = lib:
        builtins.foldl' (acc: service: acc // (evalServicePart "extraOptions" (_: {}) service lib)) {} services;
      environment = cfg:
        builtins.foldl' (acc: service: acc // (evalServicePart "environment" (_: {}) service cfg)) {} services;
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
        builtins.foldl' (acc: service: acc // (evalServicePart "extraServiceConfig" (_: {}) service cfg)) {} services;
      extraConfigs = cfg:
        builtins.map (service: evalServicePart "extraConfig" (_: {}) service cfg) services;
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

    mkBoundModuleFactory = {
      args,
      sourcePath,
      moduleFn,
      constructor,
    }: {
      __boundModuleFactory = build: let
        resolvedSourcePath =
          if sourcePath != null
          then sourcePath
          else if build ? src
          then build.src + "/default.nix"
          else throw "service-module.${constructor}: `sourcePath` is required when `package` is omitted and the build has no `src`";
      in
        {
          inputs,
          system,
          ...
        } @ moduleArgs:
          (moduleFn (
            args
            // {
              package = inputs.nixpkgs.legacyPackages.${system}.callPackage resolvedSourcePath {};
              sourcePath = resolvedSourcePath;
            }
          ))
          moduleArgs;
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
      defaultPackage = package;
      resolvedName =
        if name != null
        then name
        else defaultPackage.pname or (throw "service-module.${constructorName}: `name` is required when the package has no `pname`");
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
        || builtins.any (s: s.__hasPort or false) resolvedServices;
    in {
      inherit
        defaultPackage
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

    ########################################
    # Identity And Composable Service Parts
    ########################################

    mkIdentityHost = name: suffix: "${name}.${suffix}";
    mkIdentityUser = name: suffix: "${name}@${suffix}";
    mkIdentityCertFileName = name: suffix: "${mkIdentityHost name suffix}.crt";
    mkIdentityKeyFileName = name: suffix: "${mkIdentityHost name suffix}.key";

    mkClientIdentityCore = args @ {
      drv ? null,
      name ? null,
      pname ? (
        if drv != null
        then drv.pname or null
        else null
      ),
      sourcePath ? inferSourcePath args,
      suffix ? defaultClientIdentitySuffix,
      secretsBasePath ? null,
      certSecretFileName ? "client.crt.age",
      keySecretFileName ? "client.key.age",
      runtimeBasePath ? defaultClientRuntimeBasePath,
      secretOwner ? defaultClientSecretOwner,
      secretGroup ? defaultClientSecretGroup,
      secretMode ? defaultClientSecretMode,
    }: let
      resolvedName =
        if name != null
        then name
        else if pname != null
        then pname
        else if sourcePath != null
        then builtins.baseNameOf sourcePath
        else throw "service-module.mkClientIdentity: `name`, `pname`, or `sourcePath` is required";
      resolvedSuffix =
        if suffix != null
        then suffix
        else throw "service-module.mkClientIdentity: `suffix` is required when no defaultClientIdentitySuffix is configured";
      resolvedSecretsBasePath =
        if secretsBasePath != null
        then secretsBasePath
        else defaultClientSecretsBasePath + "/${resolvedName}";
      certFileName = mkIdentityCertFileName resolvedName resolvedSuffix;
      keyFileName = mkIdentityKeyFileName resolvedName resolvedSuffix;
      certFile = trackedPath (resolvedSecretsBasePath + "/${certSecretFileName}") "${resolvedName}-${certSecretFileName}";
      keyFile = trackedPath (resolvedSecretsBasePath + "/${keySecretFileName}") "${resolvedName}-${keySecretFileName}";
      secretDefaults = {
        owner = secretOwner;
        group = secretGroup;
        mode = secretMode;
      };
    in rec {
      inherit
        resolvedName
        resolvedSuffix
        sourcePath
        certSecretFileName
        keySecretFileName
        runtimeBasePath
        secretOwner
        secretGroup
        secretMode
        certFileName
        keyFileName
        certFile
        keyFile
        secretDefaults
        ;
      secretsBasePath = resolvedSecretsBasePath;
      __functor = _: overrideArgs:
        mkClientIdentityCore ((builtins.removeAttrs args ["drv"]) // overrideArgs // {drv = drv;});
      name = resolvedName;
      pname = resolvedName;
      suffix = resolvedSuffix;
      host = mkIdentityHost resolvedName resolvedSuffix;
      user = mkIdentityUser resolvedName resolvedSuffix;
      certRuntimePath = "${runtimeBasePath}/${certFileName}";
      keyRuntimePath = "${runtimeBasePath}/${keyFileName}";
      ageSecrets =
        (
          if certFile != null
          then {"${certFileName}" = {file = certFile;} // secretDefaults;}
          else {}
        )
        // (
          if keyFile != null
          then {"${keyFileName}" = {file = keyFile;} // secretDefaults;}
          else {}
        );
      nixosModule =
        if drv == null
        then {
          age.secrets = ageSecrets;
        }
        else
          {
            config,
            lib,
            ...
          }: {
            age.secrets = lib.mkIf (builtins.elem drv config.environment.systemPackages) ageSecrets;
          };
      flakeExtraNixosModules.clientIdentity = nixosModule;
    };

    mkClientIdentity = first:
      if builtins.isAttrs first && (first.type or null) == "derivation"
      then
        mkClientIdentityCore {
          drv = first;
        }
      else mkClientIdentityCore first;

    mkClientIdentityFor = drv: args @ {pname ? drv.pname or null, ...}:
      if pname == null
      then throw "service-module.mkClientIdentityFor: derivation must expose `pname` or `pname` must be passed explicitly"
      else (mkClientIdentity drv) ((builtins.removeAttrs args ["pname"]) // {inherit pname;});

    mkServiceIdentityHost = serviceName: mkIdentityHost serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityUser = serviceName: mkIdentityUser serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityCertFileName = serviceName: mkIdentityCertFileName serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityKeyFileName = serviceName: mkIdentityKeyFileName serviceName defaultServiceIdentitySuffix;

    mkServiceIdentity = args @ {
      serviceName ? null,
      secretsBasePath ? null,
      secretOwner ? defaultServiceSecretOwner,
      secretGroup ? defaultServiceSecretGroup,
      secretMode ? defaultServiceSecretMode,
    }: let
      identityForServiceName = serviceName:
        mkClientIdentity {
          name = serviceName;
          suffix = defaultServiceIdentitySuffix;
          inherit secretsBasePath secretOwner secretGroup secretMode;
        };
    in {
      __sourcePath = inferSourcePath args;
      __applyDefaults = resolved: {
        serviceName =
          if serviceName != null
          then serviceName
          else resolved.serviceName;
      };
      extraOptions = service: lib: let
        identity = identityForServiceName service.serviceName;
      in {
        serviceCertPath = lib.mkOption {
          type = lib.types.str;
          default = identity.certRuntimePath;
          description = "Service mTLS client certificate path.";
        };
        serviceKeyPath = lib.mkOption {
          type = lib.types.str;
          default = identity.keyRuntimePath;
          description = "Service mTLS client key path.";
        };
      };
      defaults = service: let
        identity = identityForServiceName service.serviceName;
      in {
        serviceCertPath = identity.certRuntimePath;
        serviceKeyPath = identity.keyRuntimePath;
      };
      extraConfig = service: _cfg: let
        identity = identityForServiceName service.serviceName;
      in {
        age.secrets = identity.ageSecrets;
      };
    };

    mkPostgresClientService = args @ {
      serviceName ? null,
      postgresUrlDescription ? "PostgreSQL connection URL.",
      postgresCaCertPathDescription ? "CA certificate path for PostgreSQL TLS.",
      after ? defaultPostgresAfter,
      before ? [],
      wants ? [],
      requires ? [],
      wantedBy ? [],
    }: {
      __sourcePath = inferSourcePath args;
      __applyDefaults = resolved: {
        serviceName =
          if serviceName != null
          then serviceName
          else resolved.serviceName;
      };
      extraOptions = _service: lib: {
        postgresUrl = lib.mkOption {
          type = lib.types.str;
          default = defaultPostgresUrl;
          description = postgresUrlDescription;
        };

        postgresCaCertPath = lib.mkOption {
          type = lib.types.str;
          default = defaultPostgresCaCertPath;
          description = postgresCaCertPathDescription;
        };
      };
      defaults = _service: {
        postgresUrl = defaultPostgresUrl;
        postgresCaCertPath = defaultPostgresCaCertPath;
      };

      environment = service: cfg: {
        "${service.envPrefix}_POSTGRES_URL" = cfg.postgresUrl;
        "${service.envPrefix}_POSTGRES_CA_CERT_PATH" = cfg.postgresCaCertPath;
        "${service.envPrefix}_POSTGRES_CLIENT_CERT_PATH" = cfg.serviceCertPath;
        "${service.envPrefix}_POSTGRES_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
      };

      unitConfig = _service: _cfg: {
        inherit
          after
          before
          wants
          requires
          wantedBy
          ;
      };
    };

    mkNatsClientService = args @ {
      serviceName ? null,
      natsUrlDescription ? "NATS URL.",
      natsCaCertPathDescription ? "CA certificate path for NATS mTLS.",
      after ? defaultNatsAfter,
      before ? [],
      wants ? [],
      requires ? [],
      wantedBy ? [],
    }: {
      __sourcePath = inferSourcePath args;
      __applyDefaults = resolved: {
        serviceName =
          if serviceName != null
          then serviceName
          else resolved.serviceName;
      };
      extraOptions = _service: lib: {
        natsUrl = lib.mkOption {
          type = lib.types.str;
          default = defaultNatsUrl;
          description = natsUrlDescription;
        };

        natsCaCertPath = lib.mkOption {
          type = lib.types.str;
          default = defaultNatsCaCertPath;
          description = natsCaCertPathDescription;
        };
      };
      defaults = _service: {
        natsUrl = defaultNatsUrl;
        natsCaCertPath = defaultNatsCaCertPath;
      };

      environment = service: cfg: {
        "${service.envPrefix}_NATS_URL" = cfg.natsUrl;
        "${service.envPrefix}_NATS_CA_CERT_PATH" = cfg.natsCaCertPath;
        "${service.envPrefix}_NATS_CLIENT_CERT_PATH" = cfg.serviceCertPath;
        "${service.envPrefix}_NATS_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
      };

      unitConfig = _service: _cfg: {
        inherit
          after
          before
          wants
          requires
          wantedBy
          ;
      };
    };

    mkHttpService = args @ {
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
      defaults = _service: {
        listenAddress = defaultListenAddress;
        port = defaultPort;
      };

      environment = service: cfg: {
        "${
          if bindEnvVar != null
          then bindEnvVar
          else "${service.envPrefix}_BIND_ADDR"
        }" = "${cfg.listenAddress}:${toString cfg.port}";
      };
    };
  };
}
