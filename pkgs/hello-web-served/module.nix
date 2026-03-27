{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hello-web-served;
in {
  options.services.hello-web-served = {
    enable = lib.mkEnableOption "hello-web-served example service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./default.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./default.nix {}";
      description = "The hello-web-served package to run.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the example HTTP server should bind to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18080;
      description = "Port the example HTTP server should bind to.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the selected port in the host firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [cfg.port];

    systemd.services.hello-web-served = {
      description = "hello-web-served";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      environment = {
        HELLO_WEB_BIND = cfg.listenAddress;
        HELLO_WEB_PORT = toString cfg.port;
      };
      serviceConfig = {
        DynamicUser = true;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
      };
    };
  };
}
