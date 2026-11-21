{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixbot;
  repoType = lib.types.submodule ({
    config,
    name,
    ...
  }: {
    options = {
      url = lib.mkOption {type = lib.types.str;};
      path = lib.mkOption {type = lib.types.str;};
      sshIdentityFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.sshClient.identityFiles;
      };
      syncOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      knownHostsFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${cfg.stateDir}/.ssh/known_hosts-${name}-fixture";
      };
      gitSshCommand = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "ssh -F ${cfg.sshClient.configPath} -o BatchMode=yes -i ${builtins.head config.sshIdentityFiles}";
      };
      sshUser = lib.mkOption {
        type = lib.types.str;
        default = cfg.user.name;
      };
    };
  });
in {
  options.services.nixbot = {
    enable = lib.mkEnableOption "test Nixbot fixture";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.writeShellScriptBin "nixbot" "exit 0";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixbot";
    };
    manage.ageIdentity = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "nixbot";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "nixbot";
      };
    };
    sshClient = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      configPath = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.stateDir}/.ssh/config";
      };
      identityFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
    };
    repos = lib.mkOption {
      type = lib.types.attrsOf repoType;
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.user.group} = {};
    users.users.${cfg.user.name} = {
      isSystemUser = true;
      group = cfg.user.group;
      home = cfg.stateDir;
    };
    systemd.services = lib.mapAttrs' (name: _repo:
      lib.nameValuePair "nixbot-repo-${name}-ready" {
        description = "Test Nixbot repository readiness for ${name}";
        serviceConfig.Type = "oneshot";
        script = "true";
      })
    cfg.repos;
  };
}
