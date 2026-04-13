rec {
  mkServiceLib = {
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
    defaultNatsUrl,
    defaultNatsCaCertPath,
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
      defaultNatsUrl
      defaultNatsCaCertPath
      ;

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
    mkClientIdentityFrom = mkClientIdentityFor;
    mkServiceIdentityHost = serviceName: mkIdentityHost serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityUser = serviceName: mkIdentityUser serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityCertFileName = serviceName: mkIdentityCertFileName serviceName defaultServiceIdentitySuffix;
    mkServiceIdentityKeyFileName = serviceName: mkIdentityKeyFileName serviceName defaultServiceIdentitySuffix;

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
      extraOptions = lib:
        builtins.foldl' (acc: service: acc // (evalServicePart "extraOptions" (_: {}) service lib)) {} services;
      environment = cfg:
        builtins.foldl' (acc: service: acc // (evalServicePart "environment" (_: {}) service cfg)) {} services;
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

    mkServicesModule = mkModule;

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

    mkServiceIdentity = args @ {
      serviceName ? null,
      secretsBasePath ? defaultClientSecretsBasePath,
      secretOwner ? defaultServiceSecretOwner,
      secretGroup ? defaultServiceSecretGroup,
      secretMode ? defaultServiceSecretMode,
    }: {
      __sourcePath = inferSourcePath args;
      __applyDefaults = resolved: {
        serviceName =
          if serviceName != null
          then serviceName
          else resolved.serviceName;
      };
      extraOptions = service: lib: {
        serviceCertPath = lib.mkOption {
          type = lib.types.str;
          default =
            (
              mkClientIdentity {
                name = service.serviceName;
                suffix = defaultServiceIdentitySuffix;
                inherit secretsBasePath secretOwner secretGroup secretMode;
              }
            ).certRuntimePath;
          description = "Service mTLS client certificate path.";
        };
        serviceKeyPath = lib.mkOption {
          type = lib.types.str;
          default =
            (
              mkClientIdentity {
                name = service.serviceName;
                suffix = defaultServiceIdentitySuffix;
                inherit secretsBasePath secretOwner secretGroup secretMode;
              }
            ).keyRuntimePath;
          description = "Service mTLS client key path.";
        };
      };
      extraConfig = service: _cfg: let
        identity = mkClientIdentity {
          name = service.serviceName;
          suffix = defaultServiceIdentitySuffix;
          inherit secretsBasePath secretOwner secretGroup secretMode;
        };
      in {
        age.secrets = identity.ageSecrets;
      };
    };

    mkPostgresClientService = args @ {
      serviceName ? null,
      postgresUrlDescription ? "PostgreSQL connection URL.",
      postgresCaCertPathDescription ? "CA certificate path for PostgreSQL TLS.",
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

      environment = service: cfg: {
        "${service.envPrefix}_POSTGRES_URL" = cfg.postgresUrl;
        "${service.envPrefix}_POSTGRES_CA_CERT_PATH" = cfg.postgresCaCertPath;
        "${service.envPrefix}_POSTGRES_CLIENT_CERT_PATH" = cfg.serviceCertPath;
        "${service.envPrefix}_POSTGRES_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
      };
    };

    mkNatsClientService = args @ {
      serviceName ? null,
      natsUrlDescription ? "NATS URL.",
      natsCaCertPathDescription ? "CA certificate path for NATS mTLS.",
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

      environment = service: cfg: {
        "${service.envPrefix}_NATS_URL" = cfg.natsUrl;
        "${service.envPrefix}_NATS_CA_CERT_PATH" = cfg.natsCaCertPath;
        "${service.envPrefix}_NATS_CLIENT_CERT_PATH" = cfg.serviceCertPath;
        "${service.envPrefix}_NATS_CLIENT_KEY_PATH" = cfg.serviceKeyPath;
      };
    };

    mkHttpService = args @ {
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

      environment = service: cfg: {
        "${service.envPrefix}_BIND_ADDR" = "${cfg.listenAddress}:${toString cfg.port}";
      };
    };

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
      restart ? "on-failure",
    }:
      if package == null
      then {
        __boundModuleFactory = build: let
          resolvedSourcePath =
            if sourcePath != null
            then sourcePath
            else if build ? src
            then build.src + "/default.nix"
            else throw "service-module.mkModule: `sourcePath` is required when `package` is omitted and the build has no `src`";
        in
          {
            inputs,
            system,
            ...
          } @ moduleArgs:
            (mkModule (
              args
              // {
                package = inputs.nixpkgs.legacyPackages.${system}.callPackage resolvedSourcePath {};
                sourcePath = resolvedSourcePath;
              }
            ))
            moduleArgs;
      }
      else
        {
          config,
          lib,
          ...
        }: let
          defaultPackage = package;
          resolvedName =
            if name != null
            then name
            else defaultPackage.pname or (throw "service-module.mkModule: `name` is required when the package has no `pname`");
          resolvedServiceDescription =
            if serviceDescription != null
            then serviceDescription
            else resolvedName;
          resolvedPackageDescription =
            if packageDescription != null
            then packageDescription
            else "The ${resolvedName} package to run as a service.";
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
          defaultPackageText = lib.literalExpression "package";
          cfg = config.services.${resolvedName};
        in {
          options.services.${resolvedName} =
            {
              enable = lib.mkEnableOption "${resolvedName} service";

              package = lib.mkOption {
                type = lib.types.package;
                default = defaultPackage;
                defaultText = defaultPackageText;
                description = resolvedPackageDescription;
              };
            }
            // composedServices.extraOptions lib
            // extraOptions lib;

          config = lib.mkIf cfg.enable (lib.mkMerge ([
              {
                systemd.services.${resolvedName} = {
                  description = resolvedServiceDescription;
                  wantedBy = wantedBy;
                  after = after;
                  environment = composedServices.environment cfg // environment cfg;
                  serviceConfig =
                    {
                      ExecStart = lib.getExe cfg.package;
                      Restart = restart;
                    }
                    // composedServices.extraServiceConfig cfg
                    // extraServiceConfig cfg;
                };
                _serviceModule.registeredPorts = lib.optional hasPort {
                  name = resolvedName;
                  port = cfg.port;
                };
              }
            ]
            ++ composedServices.extraConfigs cfg));
        };

    mkTcpServiceModule = {
      package ? null,
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
      restart ? "on-failure",
    }:
      mkModule {
        inherit
          package
          name
          serviceDescription
          packageDescription
          extraServiceConfig
          wantedBy
          after
          restart
          ;
        extraOptions = lib: let
          resolvedName =
            if name != null
            then name
            else "service";
        in
          {
            listenAddress = lib.mkOption {
              type = lib.types.str;
              default = defaultListenAddress;
              description =
                if listenAddressDescription != null
                then listenAddressDescription
                else "IP address for the ${resolvedName} listener.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = defaultPort;
              description =
                if portDescription != null
                then portDescription
                else "TCP port for the ${resolvedName} listener.";
            };
          }
          // extraOptions lib;
        environment = cfg:
          {
            "${bindEnvVar}" = "${cfg.listenAddress}:${toString cfg.port}";
          }
          // environment cfg;
      };
  };
}
