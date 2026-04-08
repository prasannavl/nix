rec {
  mkServiceModules = {
    self,
    name,
    serviceDescription ? name,
    packageDescription ? "The ${name} package to run as a service.",
    extraOptions ? (_: {}),
    environment ? (_: {}),
    extraServiceConfig ? (_: {}),
    wantedBy ? ["multi-user.target"],
    after ? ["network.target"],
    restart ? "on-failure",
  }: let
    serviceModule = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.${name};
    in {
      options.services.${name} =
        {
          enable = lib.mkEnableOption "${name} service";

          package = lib.mkOption {
            type = lib.types.package;
            inherit (self.packages.${pkgs.system}) default;
            defaultText =
              lib.literalExpression
              "self.packages.\${pkgs.system}.default";
            description = packageDescription;
          };
        }
        // extraOptions lib;

      config = lib.mkIf cfg.enable {
        systemd.services.${name} = {
          description = serviceDescription;
          wantedBy = wantedBy;
          after = after;
          environment = environment cfg;
          serviceConfig =
            {
              ExecStart = lib.getExe cfg.package;
              Restart = restart;
            }
            // extraServiceConfig cfg;
        };
      };
    };
  in {
    default = serviceModule;
    ${name} = serviceModule;
  };

  mkTcpServiceModules = {
    self,
    name,
    bindEnvVar,
    serviceDescription ? name,
    packageDescription ? "The ${name} package to run as a service.",
    listenAddressDescription ? "IP address for the ${name} listener.",
    portDescription ? "TCP port for the ${name} listener.",
    defaultListenAddress ? "0.0.0.0",
    defaultPort,
    extraOptions ? (_: {}),
    environment ? (_: {}),
    extraServiceConfig ? (_: {}),
    wantedBy ? ["multi-user.target"],
    after ? ["network.target"],
    restart ? "on-failure",
  }:
    mkServiceModules {
      inherit
        self
        name
        serviceDescription
        packageDescription
        extraServiceConfig
        wantedBy
        after
        restart
        ;
      extraOptions = lib:
        {
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
        }
        // extraOptions lib;
      environment = cfg:
        {
          ${bindEnvVar} = "${cfg.listenAddress}:${toString cfg.port}";
        }
        // environment cfg;
    };
}
