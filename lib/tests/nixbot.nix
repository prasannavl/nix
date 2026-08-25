{pkgs}: let
  lib = pkgs.lib;
  fakeNixbot = pkgs.writeShellScriptBin "nixbot" "exit 0";
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../../pkgs/tools/nixbot/nixos-module.nix
      {
        options.age.identityPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
        };
      }
      {
        system.stateVersion = "25.11";
        system.configurationRevision = "test-revision";
        services.nixbot = {
          enable = true;
          package = fakeNixbot;
          manage.ageIdentity = false;
          repos.z = {
            url = "ssh://git@example.invalid/abird/z";
            path = "/var/lib/nixbot/nix";
            sshUser = "nixbot";
            sshIdentityFiles = ["/var/lib/nixbot/.ssh/id_ed25519_z"];
            syncOnBoot = true;
          };
        };
      }
    ];
  };
  cfg = evaluated.config.services.nixbot;
  service = evaluated.config.systemd.services.nixbot-repo-z-ready;
  serviceScript = pkgs.writeText "nixbot-repo-z-ready-script" service.script;
  gitSshCommand = pkgs.writeText "nixbot-repo-z-git-ssh-command" cfg.repos.z.gitSshCommand;
  knownHostsFile = "/var/lib/nixbot/.ssh/known_hosts-z-${builtins.substring 0 16 (builtins.hashString "sha256" cfg.repos.z.url)}";
in
  assert service.environment.NIXBOT_REPO_URL == "ssh://git@example.invalid/abird/z";
  assert service.environment.NIXBOT_REPO_PATH == "/var/lib/nixbot/nix";
  assert service.environment.NIXBOT_REPO_KNOWN_HOSTS_FILE == knownHostsFile;
  assert service.environment.NIXBOT_REPO_SSH_KEY_PATHS == "/var/lib/nixbot/.ssh/id_ed25519_z";
  assert service.serviceConfig.User == "nixbot";
  assert service.serviceConfig.RemainAfterExit;
  assert builtins.length service.restartTriggers == 1;
    pkgs.runCommand "lib-nixbot-repo-capability-test" {} ''
      grep -F -- 'repo sync' ${serviceScript}
      grep -F -- 'UserKnownHostsFile=${knownHostsFile}' ${gitSshCommand}
      grep -F -- '/var/lib/nixbot/.ssh/id_ed25519_z' ${gitSshCommand}
      grep -F -- 'IdentitiesOnly=yes' ${gitSshCommand}
      touch "$out"
    ''
