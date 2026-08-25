{pkgs}: let
  lib = pkgs.lib;
  digest = builtins.concatStringsSep "" (lib.replicate 64 "a");
  fakeNixbot = pkgs.writeShellScriptBin "nixbot" "exit 0";
  fakeManager = pkgs.writeShellScriptBin "abird-host-manager" ''
    test -z "''${ABIRD_HOST_MANAGER_GIT:-}"
    test -n "''${GIT_SSH_COMMAND:-}"
    case "$GIT_SSH_COMMAND" in
      *'/var/lib/nixbot/.ssh/id_ed25519_z'*) ;;
      *) exit 1 ;;
    esac
    case "$ABIRD_HOST_MANAGER_PUBLISH_GIT_SSH_COMMAND" in
      *'/var/lib/nixbot/.ssh/id_ed25519_z'*) exit 1 ;;
    esac
    case "$ABIRD_HOST_MANAGER_PUBLISH_GIT_SSH_COMMAND" in
      *'UserKnownHostsFile=/var/lib/nixbot/.ssh/known_hosts-z-'*'StrictHostKeyChecking=yes'*'BatchMode=yes'*'IdentityFile=none'*'IdentityAgent=SSH_AUTH_SOCK'*'IdentitiesOnly=no'*) ;;
      *) exit 1 ;;
    esac
  '';
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    specialArgs.phaseProjections = [
      {
        intent_kind = "move";
        projection_id = "move-zulip";
        projection_sha256 = digest;
      }
      {
        intent_kind = "resource_hold";
        projection_id = "hold-zulip";
        projection_sha256 = builtins.concatStringsSep "" (lib.replicate 64 "b");
      }
    ];
    modules = [
      ../../pkgs/tools/nixbot/nixos-module.nix
      ../services/abird-host-manager
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
            sshIdentityFiles = ["/var/lib/nixbot/.ssh/id_ed25519_z"];
            syncOnBoot = true;
          };
        };
        services.abird-host-manager = {
          enable = true;
          package = fakeManager;
        };
      }
    ];
  };
  services = builtins.attrValues evaluated.config.systemd.services;
  matching = builtins.filter (service: lib.hasPrefix "Reconcile exact Abird host-manager projection" (service.description or "")) services;
  service = builtins.head matching;
  managerRuntime = lib.findFirst (package: lib.getName package == "abird-host-manager-runtime") null evaluated.config.environment.systemPackages;
in
  assert builtins.length matching == 1;
  assert !(lib.hasInfix "hold-zulip" service.script);
  assert lib.hasInfix "transaction reconcile move-zulip" service.script;
  assert lib.hasInfix "--expected-projection-sha256 ${digest}" service.script;
  assert service.serviceConfig.User == "nixbot";
  assert service.requires == ["nixbot-repo-z-ready.service"];
  assert lib.elem "nixbot-repo-z-ready.service" service.after;
  assert managerRuntime != null;
    pkgs.runCommand "lib-abird-host-manager-controller-test" {} ''
      ${lib.getExe' managerRuntime "abird-host-manager"}
      touch "$out"
    ''
