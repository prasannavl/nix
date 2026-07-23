{pkgs}: let
  lib = pkgs.lib;

  commonModule = {
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    users.users = {
      alice = {
        isNormalUser = true;
        uid = 1001;
        group = "alice";
        extraGroups = ["ops"];
        home = "/home/alice";
      };
      bob = {
        isNormalUser = true;
        uid = 1002;
        group = "bob";
        home = "/home/bob";
      };
    };
    users.groups = {
      alice.gid = 1001;
      bob.gid = 1002;
      ops.gid = 3000;
    };
  };

  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      ../default.nix
      commonModule
      {
        services.systemd-user-manager.instances = {
          zeta = {
            user = "alice";
            unit = "zeta.service";
            removalPolicy = "keep";
            autoStart = false;
            state = "stopped";
            timeoutReadySeconds = 17;
            restartTriggers = ["restart-a"];
            reloadTriggers = ["reload-a"];
            verifyCommand = ["/bin/true"];
            transitionNeutralStamp = "neutral-a";
            stopOnTransitionFrom = "old-token";
            stopOnTransitionTo = "new-token";
          };

          alpha = {
            user = "alice";
            unit = "alpha.timer";
            removalCommand = ["/bin/systemctl" "--user" "stop" "alpha.timer"];
            restartTriggers = ["restart-b"];
            verifyCommand = ["/bin/true" "--alpha"];
            stampPayload = {
              kind = "custom";
              value = 1;
            };
          };

          beta = {
            user = "bob";
            restartTriggers = ["restart-c"];
          };

          slow-apply = {
            user = "bob";
            unit = "slow-apply.service";
            startMode = "enqueue";
            timeoutReadySeconds = 360;
            restartTriggers = ["restart-d"];
          };
        };
      }
    ];
  };
  duplicateEvalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      ../default.nix
      commonModule
      {
        services.systemd-user-manager.instances = {
          dup-a = {
            user = "alice";
            unit = "dup.service";
          };
          dup-b = {
            user = "alice";
            unit = "dup.service";
          };
        };
      }
    ];
  };

  config = evalConfig.config;
  startConcurrencyOption = evalConfig.options.services.systemd-user-manager.startConcurrency;
  failedAssertions = builtins.filter (assertion: ! assertion.assertion) config.assertions;
  duplicateConfig = duplicateEvalConfig.config;
  duplicateFailedAssertions = builtins.filter (assertion: ! assertion.assertion) duplicateConfig.assertions;
  duplicateFailedMessages = map (assertion: assertion.message) duplicateFailedAssertions;

  metadataPathFromEnv = env: let
    prefix = "SYSTEMD_USER_MANAGER_METADATA=";
    matches = builtins.filter (entry: lib.hasPrefix prefix entry) env;
  in
    assert builtins.length matches == 1;
      lib.removePrefix prefix (builtins.head matches);

  metadataFromSystemService = service:
    builtins.fromJSON (builtins.readFile (metadataPathFromEnv service.serviceConfig.Environment));

  aliceDispatcher = config.systemd.services.systemd-user-manager-dispatcher-alice;
  bobDispatcher = config.systemd.services.systemd-user-manager-dispatcher-bob;
  aliceReconciler = config.systemd.user.services.systemd-user-manager-reconciler-alice;
  bobReconciler = config.systemd.user.services.systemd-user-manager-reconciler-bob;
  aliceMetadata = metadataFromSystemService aliceDispatcher;
  bobMetadata = metadataFromSystemService bobDispatcher;
  aliceUnitNames = map (unit: unit.name) aliceMetadata.managedUnits;
  alphaUnit = builtins.elemAt aliceMetadata.managedUnits 0;
  zetaUnit = builtins.elemAt aliceMetadata.managedUnits 1;
  bobUnit = builtins.head bobMetadata.managedUnits;
  slowApplyUnit = builtins.elemAt bobMetadata.managedUnits 1;
in
  assert failedAssertions == [];
  assert startConcurrencyOption.default == 4;
  assert startConcurrencyOption.type.check (-1);
  assert !(startConcurrencyOption.type.check 0);
  assert config.environment.etc."systemd-user-manager/dispatchers/systemd-user-manager-dispatcher-alice.metadata".text == "${metadataPathFromEnv aliceDispatcher.serviceConfig.Environment}\n";
  assert aliceDispatcher.after
  == [
    "systemd-tmpfiles-setup.service"
    "systemd-tmpfiles-resetup.service"
    "user@1001.service"
  ];
  assert aliceDispatcher.wants == ["user@1001.service"];
  assert aliceDispatcher.wantedBy == ["multi-user.target"];
  assert aliceDispatcher.serviceConfig.User == "root";
  assert aliceDispatcher.serviceConfig.Type == "oneshot";
  assert aliceDispatcher.serviceConfig.RemainAfterExit == true;
  assert aliceDispatcher.serviceConfig.Environment
  == [
    "SYSTEMD_USER_MANAGER_USER=alice"
    "SYSTEMD_USER_MANAGER_UID=1001"
    "SYSTEMD_USER_MANAGER_METADATA=${metadataPathFromEnv aliceDispatcher.serviceConfig.Environment}"
    "SYSTEMD_USER_MANAGER_RECONCILER_SERVICE=systemd-user-manager-reconciler-alice.service"
  ];
  assert lib.hasSuffix " dispatcher-start" aliceDispatcher.serviceConfig.ExecStart;
  assert aliceDispatcher.serviceConfig.TimeoutStartSec == 180;
  assert aliceDispatcher.serviceConfig.TimeoutStopSec == 180;
  assert aliceReconciler.serviceConfig.Type == "oneshot";
  assert aliceReconciler.serviceConfig.RemainAfterExit == true;
  assert aliceReconciler.serviceConfig.TimeoutStartSec == 180;
  assert lib.hasSuffix " reconciler-apply" aliceReconciler.serviceConfig.ExecStart;
  assert aliceReconciler.serviceConfig.Environment
  == [
    "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
    "SYSTEMD_USER_MANAGER_USER=alice"
    "SYSTEMD_USER_MANAGER_METADATA=${metadataPathFromEnv aliceReconciler.serviceConfig.Environment}"
    "SYSTEMD_USER_MANAGER_START_CONCURRENCY=4"
  ];
  assert bobDispatcher.serviceConfig.Environment
  == [
    "SYSTEMD_USER_MANAGER_USER=bob"
    "SYSTEMD_USER_MANAGER_UID=1002"
    "SYSTEMD_USER_MANAGER_METADATA=${metadataPathFromEnv bobDispatcher.serviceConfig.Environment}"
    "SYSTEMD_USER_MANAGER_RECONCILER_SERVICE=systemd-user-manager-reconciler-bob.service"
  ];
  assert bobDispatcher.serviceConfig.TimeoutStartSec == 420;
  assert bobDispatcher.serviceConfig.TimeoutStopSec == 420;
  assert bobReconciler.serviceConfig.TimeoutStartSec == 420;
  assert aliceMetadata.version == 9;
  assert aliceMetadata.user == "alice";
  assert aliceUnitNames == ["alpha" "zeta"];
  assert alphaUnit.unit == "alpha.timer";
  assert alphaUnit.removalPolicy == "stop";
  assert alphaUnit.removalCommand == ["/bin/systemctl" "--user" "stop" "alpha.timer"];
  assert alphaUnit.verifyCommand == ["/bin/true" "--alpha"];
  assert alphaUnit.autoStart == true;
  assert alphaUnit.startMode == "wait";
  assert alphaUnit.state == "running";
  assert alphaUnit.timeoutReadySeconds == 120;
  assert alphaUnit.reloadStamp == "";
  assert alphaUnit.stamp
  == builtins.hashString "sha256" (builtins.toJSON {
    payload = {
      kind = "custom";
      value = 1;
    };
    autoStart = true;
    state = "running";
  });
  assert zetaUnit.unit == "zeta.service";
  assert zetaUnit.removalPolicy == "keep";
  assert zetaUnit.verifyCommand == ["/bin/true"];
  assert zetaUnit.autoStart == false;
  assert zetaUnit.startMode == "wait";
  assert zetaUnit.state == "stopped";
  assert zetaUnit.timeoutReadySeconds == 17;
  assert zetaUnit.reloadStamp != "";
  assert zetaUnit.transitionNeutralStamp == "neutral-a";
  assert zetaUnit.stopOnTransitionFrom == "old-token";
  assert zetaUnit.stopOnTransitionTo == "new-token";
  assert bobMetadata.user == "bob";
  assert bobUnit.name == "beta";
  assert bobUnit.unit == "beta.service";
  assert slowApplyUnit.name == "slow-apply";
  assert slowApplyUnit.startMode == "enqueue";
  assert config.systemd.user.targets.systemd-user-manager-ready.description == "Managed user units ready target";
  assert duplicateFailedMessages
  == [
    "services.systemd-user-manager: duplicate managed user units are not allowed: alice: dup.service"
  ];
  assert lib.hasInfix "activation-stop-applied" config.system.activationScripts.systemd-user-manager-stop-applied.text;
  assert lib.hasInfix "activation-dry-preview" config.system.activationScripts.systemd-user-manager-dry-activate-preview.text;
    pkgs.runCommand "systemd-user-manager-module-test" {} ''
      touch "$out"
    ''
