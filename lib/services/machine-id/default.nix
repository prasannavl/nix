{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services."machine-id";
in {
  options.services."machine-id" = {
    enable = lib.mkEnableOption "stable machine identity material";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/machine";
      description = "Directory that stores stable machine identity material.";
    };

    opensshHostKeys.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to store OpenSSH host keys under the machine identity directory.";
    };

    runtimeHostname.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to converge the runtime hostname after boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root -"
    ];

    services.openssh.hostKeys = lib.mkIf cfg.opensshHostKeys.enable [
      {
        path = "${cfg.stateDir}/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "${cfg.stateDir}/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];

    systemd.services.machine-id-runtime-hostname = lib.mkIf cfg.runtimeHostname.enable {
      description = "Converge runtime hostname";
      wantedBy = [
        "multi-user.target"
        "sysinit-reactivation.target"
      ];
      before = ["tailscaled.service"];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        desired_hostname=${lib.escapeShellArg config.networking.hostName}
        current_hostname="$(${pkgs.hostname-debian}/bin/hostname 2>/dev/null || true)"

        if [ -n "$desired_hostname" ] && [ "$current_hostname" != "$desired_hostname" ]; then
          ${pkgs.hostname-debian}/bin/hostname "$desired_hostname" || true
        fi
      '';
    };
  };
}
