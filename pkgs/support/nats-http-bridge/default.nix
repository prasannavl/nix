{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
  pkg = s.pkg;
  srv = s.srv;
  lib = pkgs.lib;
  configLib = import ./nix/config.nix {
    lib = lib;
    pkgs = pkgs;
  };
in
  pkg.mkRustDerivation {
    pkgs = pkgs;
    pname = "nats-http-bridge";
    version = "0.1.0";
    projectDir = "pkgs/support/nats-http-bridge";
    nativeCheckInputs = [
      pkgs.nats-server
    ];
    enableDevShell = true;
    meta = {
      description = "Bridge core NATS or JetStream subscriptions to HTTP endpoints";
      mainProgram = "nats-http-bridge";
    };
    extraPassthru = {
      inherit (configLib) mkConfigText validateConfig;

      nixosModule = srv.mkServicesModule {
        envPrefix = "NATS_HTTP_BRIDGE";
        restart = "always";
        services = [
          (srv.mkServiceIdentity {})
          (srv.mkNatsClientService {})
        ];
        extraOptions = lib: {
          configPath = lib.mkOption {
            type = lib.types.path;
            description = "YAML config file consumed by nats-http-bridge.";
          };

          httpTimeoutSecs = lib.mkOption {
            type = lib.types.ints.positive;
            default = 30;
            description = "HTTP timeout passed to nats-http-bridge in seconds.";
          };

          logFilter = lib.mkOption {
            type = lib.types.str;
            default = "info";
            description = "Tracing filter passed to nats-http-bridge.";
          };
        };
        extraServiceConfig = cfg: {
          ExecStart = ''
            ${pkgs.lib.getExe cfg.package} \
              --config ${cfg.configPath} \
              --server ${pkgs.lib.escapeShellArg cfg.natsUrl} \
              --ca-cert ${pkgs.lib.escapeShellArg cfg.natsCaCertPath} \
              --client-cert ${pkgs.lib.escapeShellArg cfg.serviceCertPath} \
              --client-key ${pkgs.lib.escapeShellArg cfg.serviceKeyPath} \
              --http-timeout-secs ${toString cfg.httpTimeoutSecs} \
              --log-filter ${pkgs.lib.escapeShellArg cfg.logFilter}
          '';
          RestartSec = "5s";
        };
      };
    };
  }
