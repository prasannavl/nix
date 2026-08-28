{pkgs}: let
  lib = pkgs.lib;
  digest = builtins.concatStringsSep "" (lib.replicate 64 "a");
  controllerOverride = pkgs.writeText "controller.override.nix" ''
    {
      hosts.controller.proxyCommand = null;
    }
  '';
  fakeNixbot = pkgs.writeShellScriptBin "nixbot" "exit 0";
  fakeManager = pkgs.writeShellScriptBin "abird-host-manager" ''
    test -z "''${ABIRD_HOST_MANAGER_GIT:-}"
    test "''${ABIRD_HOST_MANAGER_CONFIG_OVERRIDE:-}" = ${lib.escapeShellArg (toString controllerOverride)}
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
    specialArgs = {
      phaseProjections = [
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
        {
          intent_kind = "move";
          projection_id = "move-local";
          projection_sha256 = builtins.concatStringsSep "" (lib.replicate 64 "c");
        }
      ];
      servicePlacements = {
        controller_reconcile_exclusions = ["move-local"];
        closeouts = {
          move-zulip = {
            affected_hosts = ["source" "target" "proxy"];
            decision = "complete";
            projection_sha256 = digest;
          };
          move-local = {
            affected_hosts = ["source" "target"];
            controller_reconcile = false;
            decision = "complete";
            projection_sha256 = builtins.concatStringsSep "" (lib.replicate 64 "d");
          };
        };
      };
      serviceMoveContract.moves.move-native = {
        affected_hosts = ["source" "target"];
        declaration = {
          authority = "controller";
          decision = "complete";
        };
        projection.projection_sha256 = builtins.concatStringsSep "" (lib.replicate 64 "e");
      };
    };
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
          configOverride = controllerOverride;
          failedJobSupersessionProjections = ["move-zulip"];
        };
      }
    ];
  };
  services = builtins.attrValues evaluated.config.systemd.services;
  matching = builtins.filter (service: lib.hasPrefix "Reconcile exact Abird host-manager projection" (service.description or "")) services;
  service = builtins.head matching;
  evaluatedWithoutSupersession = evaluated.extendModules {
    modules = [
      {
        services.abird-host-manager.failedJobSupersessionProjections = lib.mkForce [];
      }
    ];
  };
  servicesWithoutSupersession = builtins.attrValues evaluatedWithoutSupersession.config.systemd.services;
  matchingWithoutSupersession = builtins.filter (candidate: lib.hasPrefix "Reconcile exact Abird host-manager projection" (candidate.description or "")) servicesWithoutSupersession;
  serviceWithoutSupersession = builtins.head matchingWithoutSupersession;
  closeoutMatching = builtins.filter (candidate: lib.hasPrefix "Finalize deployed Abird host-manager closeout" (candidate.description or "")) services;
  closeoutService = builtins.head closeoutMatching;
  managerRuntime = lib.findFirst (package: lib.getName package == "abird-host-manager-runtime") null evaluated.config.environment.systemPackages;
in
  assert builtins.length matching == 1;
  assert !(lib.hasInfix "hold-zulip" service.script);
  assert lib.hasInfix "transaction _reconcile move-zulip" service.script;
  assert lib.hasInfix "--expected-projection-sha256 ${digest}" service.script;
  assert lib.hasInfix "--supersede-failed-job" service.script;
  assert builtins.length matchingWithoutSupersession == 1;
  assert lib.hasInfix "transaction _reconcile move-zulip" serviceWithoutSupersession.script;
  assert !(lib.hasInfix "--supersede-failed-job" serviceWithoutSupersession.script);
  assert builtins.length closeoutMatching == 1;
  assert !(lib.any (candidate: lib.hasInfix "move-native" (candidate.script or "")) closeoutMatching);
  assert lib.hasInfix "transaction _close-reconcile" closeoutService.script;
  assert lib.hasInfix "--expected-projection-sha256 ${digest}" closeoutService.script;
  assert service.serviceConfig.User == "nixbot";
  assert service.environment.ABIRD_HOST_MANAGER_CONFIG_OVERRIDE == toString controllerOverride;
  assert service.requires == ["nixbot-repo-z-ready.service"];
  assert lib.elem "nixbot-repo-z-ready.service" service.after;
  assert managerRuntime != null;
    pkgs.runCommand "lib-abird-host-manager-controller-test" {} ''
      ${lib.getExe' managerRuntime "abird-host-manager"}
      touch "$out"
    ''
