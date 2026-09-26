{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pi-web;

  # Loopback by default; a tailnet-exposed service listens on all interfaces
  # and relies on the tailscale0-scoped firewall rule below for reachability.
  effectiveBindAddress =
    if cfg.bindAddress != null
    then cfg.bindAddress
    else if cfg.tailnetAccess
    then "0.0.0.0"
    else "127.0.0.1";

  userHome = config.users.users.${cfg.user}.home;
in {
  options.services.pi-web = {
    enable = lib.mkEnableOption "the Pi Web UI server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../ext/pi/pi-web {};
      defaultText = lib.literalExpression "pkgs.callPackage ../../ext/pi/pi-web {}";
      description = "Pi Web package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 30141;
      description = "TCP port for the Pi Web UI.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "pvl";
      description = "User that runs Pi Web and owns the Pi agent state.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0.0.0.0";
      description = ''
        Address to bind. When null, the service binds `0.0.0.0` if
        {option}`services.pi-web.tailnetAccess` is enabled and `127.0.0.1`
        otherwise.
      '';
    };

    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["pvl-l5" "pvl-l5.tailcaaad.ts.net"];
      description = ''
        Extra exact hostnames accepted in the HTTP Host header
        (`PI_WEB_ALLOWED_HOSTS`). Pi Web rejects unknown hostnames but accepts
        raw loopback and interface IPs without this list.
      '';
    };

    tailnetAccess = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose the configured port to the Tailscale interface with a scoped
        firewall rule. The port stays closed on every other interface.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/agenix/pi-web";
      description = ''
        Optional systemd environment file. Use it to set
        `PI_WEB_PASSWORD` (and any other `PI_WEB_*` variables) from a secret
        store such as agenix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.tailnetAccess || effectiveBindAddress != "127.0.0.1";
        message = "services.pi-web.tailnetAccess requires a non-loopback bindAddress.";
      }
      {
        assertion = !cfg.tailnetAccess || config.services.tailscale.enable;
        message = "services.pi-web.tailnetAccess requires services.tailscale.enable.";
      }
    ];

    systemd.services.pi-web = {
      description = "Pi Web UI";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        WorkingDirectory = userHome;
        Environment =
          [
            "HOME=${userHome}"
            "PI_WEB_NO_OPEN=1"
            "PI_WEB_SKIP_VERSION_CHECK=1"
          ]
          ++ lib.optional (cfg.allowedHosts != []) "PI_WEB_ALLOWED_HOSTS=${lib.concatStringsSep "," cfg.allowedHosts}";
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        ExecStart = "${lib.getExe cfg.package} --no-open --hostname ${effectiveBindAddress} --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
      };
    };

    # Reachable from every tailnet node via MagicDNS, closed everywhere else.
    networking.firewall.extraInputRules = lib.mkIf cfg.tailnetAccess ''
      iifname "tailscale0" tcp dport ${toString cfg.port} accept comment "Pi Web UI over Tailscale"
    '';
  };
}
