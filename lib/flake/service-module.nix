rec {
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
    then throw "service-module.mkModule: cannot infer source path from empty argument set"
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

  mkNatsService = args @ {
    envPrefix ? null,
    serviceName ? null,
    natsUrlDescription ? "NATS URL.",
    natsCaCertPathDescription ? "CA certificate path for NATS mTLS.",
    natsClientCertPathDescription ? "Client certificate path for NATS mTLS.",
    natsClientKeyPathDescription ? "Client key path for NATS mTLS.",
  }: {
    __sourcePath = inferSourcePath args;
    __applyDefaults = resolved: {
      serviceName =
        if serviceName != null
        then serviceName
        else resolved.serviceName;
    };
    extraOptions = service: lib: {
      natsUrl = lib.mkOption {
        type = lib.types.str;
        default = "tls://127.0.0.1:4222";
        description = natsUrlDescription;
      };

      natsCaCertPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/agenix/nats-ca-cert";
        description = natsCaCertPathDescription;
      };

      natsClientCertPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/agenix/${service.serviceName}.srv.z.gap.ai.crt";
        description = natsClientCertPathDescription;
      };

      natsClientKeyPath = lib.mkOption {
        type = lib.types.str;
        default = "/run/agenix/${service.serviceName}.srv.z.gap.ai.key";
        description = natsClientKeyPathDescription;
      };
    };

    environment = service: cfg: {
      "${service.envPrefix}_NATS_URL" = cfg.natsUrl;
      "${service.envPrefix}_NATS_CA_CERT_PATH" = cfg.natsCaCertPath;
      "${service.envPrefix}_NATS_CLIENT_CERT_PATH" = cfg.natsClientCertPath;
      "${service.envPrefix}_NATS_CLIENT_KEY_PATH" = cfg.natsClientKeyPath;
    };
  };

  mkHttpService = args @ {
    envPrefix ? null,
    listenAddressDescription ? "IP address for the listener.",
    portDescription ? "TCP port for the listener.",
    defaultListenAddress ? "0.0.0.0",
    defaultPort,
  }: {
    __sourcePath = inferSourcePath args;
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
    sourcePath ? inferSourcePath args,
    packagePath ? sourcePath,
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
  }: {
    config,
    lib,
    pkgs,
    ...
  }: let
    defaultPackage =
      if package != null
      then package
      else pkgs.callPackage packagePath {};
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
    defaultPackageText =
      if package != null
      then lib.literalExpression "package"
      else lib.literalExpression "pkgs.callPackage ${toString packagePath} {}";
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

    config = lib.mkIf cfg.enable {
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
    };
  };

  mkTcpServiceModule = {
    package ? null,
    packagePath ? null,
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
        packagePath
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
}
