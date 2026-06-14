{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.fail2ban-helper;
  actionName = "fail2ban-helper-nftables";
  tableName = "fail2ban_helper";
  ipv4ExactSet = "exact4";
  ipv6ExactSet = "exact6";
  ipv6PrefixSet = "prefix6";
  helper = pkgs.writeShellApplication {
    name = "fail2ban-helper";
    runtimeInputs = [
      pkgs.nftables
      pkgs.python3
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./fail2ban-helper.py} "$@"
    '';
  };
  commonActionArgs = lib.concatStringsSep " " [
    "--table ${tableName}"
    "--ipv4-exact-set ${ipv4ExactSet}"
    "--ipv6-exact-set ${ipv6ExactSet}"
    "--ipv6-prefix-set ${ipv6PrefixSet}"
    "--ipv6-prefix-length ${toString cfg.ipv6PrefixLength}"
    "--state-dir ${cfg.stateDir}"
    "--prefix-timeout ${toString cfg.prefixBanSeconds}"
    "--escalation-find-time ${toString cfg.escalation.findTimeSeconds}"
    "--escalation-max-retry ${toString cfg.escalation.maxRetry}"
  ];
  rejectVerdict =
    if cfg.blockVerdict == "drop"
    then "drop"
    else "reject";
  nginxLogPath =
    if cfg.nginx.logPaths == []
    then null
    else lib.concatStringsSep " " cfg.nginx.logPaths;
in {
  options.services.fail2ban-helper = {
    enable = lib.mkEnableOption "provider-agnostic host-local fail2ban helper";

    ipv6PrefixLength = lib.mkOption {
      type = lib.types.ints.between 1 128;
      default = 64;
      description = "IPv6 prefix length used when escalating repeated exact-address bans.";
    };

    blockVerdict = lib.mkOption {
      type = lib.types.enum [
        "reject"
        "drop"
      ];
      default = "reject";
      description = "nftables verdict for fail2ban-helper bans.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fail2ban/fail2ban-helper";
      description = "State directory used to count IPv6 prefix ban escalation.";
    };

    exactBanSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Base timeout for first-stage exact IP bans before fail2ban repeat-offender escalation.";
    };

    prefixBanSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Timeout for escalated IPv6 prefix bans.";
    };

    bantimeIncrement = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable fail2ban's native repeat-offender bantime escalation.";
      };

      multipliers = lib.mkOption {
        type = lib.types.str;
        default = "1 2 6";
        description = "Fail2ban bantime multipliers applied to the base exact ban time.";
      };

      maxTime = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "Maximum exact ban time when repeat-offender bantime escalation is enabled.";
      };

      overallJails = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Count prior bans across all fail2ban jails when escalating exact ban time.";
      };
    };

    escalation = {
      maxRetry = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Exact IPv6 bans from one prefix before escalating to a prefix ban.";
      };

      findTimeSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Window used to count IPv6 exact bans for prefix escalation.";
      };
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable a fail2ban jail for nginx limit_req events.";
      };

      logPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Host paths to nginx error logs used by the nginx limit_req fail2ban jail.";
      };

      maxRetry = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "nginx limit_req events before fail2ban exact-bans a client.";
      };

      findTimeSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Window for nginx limit_req fail2ban matching.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nginx.enable -> cfg.nginx.logPaths != [];
        message = "services.fail2ban-helper.nginx.logPaths must be set when the nginx fail2ban helper is enabled.";
      }
      {
        assertion = config.networking.nftables.enable;
        message = "services.fail2ban-helper requires networking.nftables.enable.";
      }
      {
        assertion = config.services.fail2ban.enable;
        message = "services.fail2ban-helper requires services.fail2ban.enable.";
      }
    ];

    environment = {
      systemPackages = [helper];
      etc."fail2ban/action.d/${actionName}.conf".text = ''
        [Definition]
        actionban = ${helper}/bin/fail2ban-helper ban ${commonActionArgs} --exact-timeout <bantime> --ip <ip>
        actionprolong = %(actionban)s
        actionunban = ${helper}/bin/fail2ban-helper unban ${commonActionArgs} --ip <ip>

        [Init]
      '';
    };

    systemd = {
      services.fail2ban.after = lib.mkIf cfg.nginx.enable [
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-resetup.service"
      ];

      tmpfiles.rules = [
        "d ${cfg.stateDir} 0750 root root -"
      ];
    };

    networking.nftables.tables.${tableName} = {
      family = "inet";
      content = ''
        set ${ipv4ExactSet} {
          type ipv4_addr
          flags timeout
        }

        set ${ipv6ExactSet} {
          type ipv6_addr
          flags timeout
        }

        set ${ipv6PrefixSet} {
          type ipv6_addr
          flags interval,timeout
        }

        chain input {
          type filter hook input priority -110; policy accept;
          ip saddr @${ipv4ExactSet} counter ${rejectVerdict}
          ip6 saddr @${ipv6ExactSet} counter ${rejectVerdict}
          ip6 saddr @${ipv6PrefixSet} counter ${rejectVerdict}
        }
      '';
    };

    services.fail2ban = {
      banaction = lib.mkDefault actionName;
      bantime = lib.mkDefault "${toString cfg.exactBanSeconds}s";
      "bantime-increment" = lib.mkIf cfg.bantimeIncrement.enable {
        enable = true;
        multipliers = cfg.bantimeIncrement.multipliers;
        maxtime = cfg.bantimeIncrement.maxTime;
        overalljails = cfg.bantimeIncrement.overallJails;
      };
      jails = lib.mkIf cfg.nginx.enable {
        nginx-limit-req.settings = {
          enabled = true;
          filter = "nginx-limit-req[logtype=file]";
          logpath = nginxLogPath;
          backend = "auto";
          maxretry = cfg.nginx.maxRetry;
          findtime = "${toString cfg.nginx.findTimeSeconds}s";
          action = "${actionName}[name=nginx-limit-req]";
        };
      };
    };
  };
}
