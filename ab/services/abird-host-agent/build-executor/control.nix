{
  config,
  lib,
  ...
}: let
  cfg = config.services.abird-host-agent.buildExecutor.control;
  package = config.services.abird-host-agent.package;
  runtime = "/run/abird/abird-host-agent/owned-build";
  authority = "${cfg.xdgStateHome}/abird/abird-host-agent/owned-build";
in {
  options.services.abird-host-agent.buildExecutor.control = {
    enable = lib.mkEnableOption "owned-build authenticated control (submission defaults closed)";
    declarationFile = lib.mkOption {
      type = lib.types.path;
      description = "Root-controlled generated JSON: identity, admission policy and UID/issuer mapping.";
    };
    xdgStateHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib";
      description = "Absolute XDG state base; project namespace is fixed.";
    };
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Socket access only; kernel UID must also match a declared principal, never the worker UID.";
    };
    slice = lib.mkOption {
      type = lib.types.str;
      default = "system.slice";
      description = "Independent control accounting slice, never the owned workload slice.";
    };
    maxConnections = lib.mkOption {
      type = lib.types.ints.between 1 64;
      description = "Explicit control-reserve connection bound; no production budget default.";
    };
    connectionLifetimeSeconds = lib.mkOption {
      type = lib.types.ints.between 1 60;
      description = "Explicit per-connection service lifetime, including stalled journal I/O.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.xdgStateHome && !(lib.elem ".." (lib.splitString "/" cfg.xdgStateHome));
        message = "Agent-managed build control requires an absolute, nontraversing XDG state base.";
      }
    ];
    environment.systemPackages = [package];
    users.groups.abird-owned-control.members = cfg.users;
    # No state directory creation, authority initialization or boot reconciliation.
    systemd = {
      tmpfiles.rules = ["d ${runtime} 0750 root abird-owned-control -"];
      sockets.abird-owned-build-control = {
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = "${runtime}/control.sock";
          Accept = true;
          SocketUser = "root";
          SocketGroup = "abird-owned-control";
          SocketMode = "0660";
          MaxConnections = cfg.maxConnections;
          Backlog = cfg.maxConnections;
          RemoveOnStop = true;
        };
      };
      services."abird-owned-build-control@" = {
        # Independent process/connection, outside the workload and controller lock.
        environment = {
          XDG_STATE_HOME = cfg.xdgStateHome;
          HOME = "/var/empty";
        };
        serviceConfig = {
          ExecStart = "${package}/bin/abird-host-agent _owned-control --config ${lib.escapeShellArg (toString cfg.declarationFile)}";
          User = "root";
          Group = "root";
          Slice = cfg.slice;
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
          Restart = "no";
          RuntimeMaxSec = cfg.connectionLifetimeSeconds;
          TimeoutStopSec = "1s";
          LimitCORE = 0;
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = ["-${authority}"];
          RestrictAddressFamilies = ["AF_UNIX"];
        };
      };
    };
  };
}
