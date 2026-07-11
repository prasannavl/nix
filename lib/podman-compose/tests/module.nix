{pkgs}: let
  lib = pkgs.lib;
  sourceAttrs = import ./examples/source-attrs.nix;
  sourceInlineText = import ./examples/source-inline-text.nix;
  sourceFile = ./examples/source-file.compose.yml;

  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      ../default.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };

        users.users.tester = {
          isNormalUser = true;
          uid = 1234;
          group = "tester";
          home = "/home/tester";
        };
        users.groups.tester.gid = 1234;

        services.podman-compose.demo = {
          user = "tester";
          stackDir = "/srv/demo";
          servicePrefix = "demo-";
          reconcilePolicy = "auto";
          removalPolicy = "delete";
          autoStart = true;
          timeoutReadySeconds = 45;

          instances = {
            app = {
              source = sourceAttrs;
              composeArgs = ["--project-name" "demo-app"];
              dependsOn = ["db" "external-ready.service"];
              wants = ["optional"];
              waitForNetwork = true;
              longRunning = false;
              startStateStallSeconds = 75;
              imageTag = "image-1";
              bootTag = "boot-1";
              reloadTag = "reload-1";
              recreateTag = "recreate-1";
              preStart = ["printf start"];
              postStart = ["printf post"];
              preStop = ["-printf stop"];
              reload = {
                method = "signal";
                signal = "USR1";
                services = ["web"];
                trigger = {
                  dirs = ["reload"];
                  externalFiles = ["external-reload.txt"];
                };
              };
              recreate.trigger.files = ["manual-recreate.txt"];
              exposedPorts = {
                http = {
                  port = 18080;
                  openFirewall = true;
                  tunnels = [
                    {
                      kind = "cloudflare";
                      hostNames = ["app.example.test"];
                      targetPort = 18082;
                    }
                    {
                      kind = "rathole";
                      name = "app-rathole";
                      hostNames = ["app-rathole.example.test"];
                      targetPort = 18083;
                      remotePort = 443;
                    }
                  ];
                };
                dns = {
                  port = 1053;
                  protocols = ["udp"];
                  openFirewall = true;
                };
              };
              dirs.reload = {
                mode = "0750";
                user = 1000;
                group = 1000;
                scope = "container";
              };
              files = {
                "config/app.yml".text = "setting: true\n";
                "reload/web.conf".text = "worker_processes 1;\n";
                "external-reload.txt".text = "reloadable\n";
                "manual-recreate.txt".text = "recreate\n";
                "other.txt".text = "ordinary\n";
              };
              envSecrets.web = {
                APP_TOKEN = "/run/secrets/app-token";
              };
              fileSecrets."db-password" = {
                file = "/run/secrets/db-password";
                mountPath = "/run/app/db-password";
                services = ["web"];
              };
            };

            db.source.services.db.image = "docker.io/library/postgres:latest";

            "text-source".source = sourceInlineText;

            "file-source".source = sourceFile;

            "opaque-secret" = {
              source = ''
                services:
                  opaque-secret:
                    image: docker.io/library/busybox:latest
                    command: ["sh", "-c", "cat /run/secrets/default-token"]
              '';
              fileSecrets."default-token" = {
                file = "/run/secrets/default-token";
              };
            };

            job = {
              user = "root";
              serviceName = "demo-custom-job";
              state = "stopped";
              autoStart = true;
              removalPolicy = "keep";
              longRunning = false;
              source.services.job.image = "docker.io/library/busybox:latest";
            };

            "restart-policy" = {
              reconcilePolicy = "restart";
              source.services.web.image = "docker.io/library/nginx:latest";
              files."ordinary.txt".text = "restart ordinary\n";
            };

            "recreate-policy" = {
              reconcilePolicy = "recreate";
              source.services.web.image = "docker.io/library/nginx:latest";
              files."ordinary.txt".text = "recreate ordinary\n";
            };
          };
        };
      }
    ];
  };

  config = evalConfig.config;
  stack = config.services.podman-compose.demo;
  app = stack.instances.app;
  db = stack.instances.db;
  textSource = stack.instances."text-source";
  fileSource = stack.instances."file-source";
  opaqueSecret = stack.instances."opaque-secret";
  job = stack.instances.job;
  restartPolicy = stack.instances."restart-policy";
  recreatePolicy = stack.instances."recreate-policy";
  appUnit = config.systemd.user.services.demo-app;
  dbUnit = config.systemd.user.services.demo-db;
  textSourceUnit = config.systemd.user.services.demo-text-source;
  fileSourceUnit = config.systemd.user.services.demo-file-source;
  opaqueSecretUnit = config.systemd.user.services.demo-opaque-secret;
  jobUnit = config.systemd.user.services.demo-custom-job;
  appStageUnit = config.systemd.user.services.demo-app-stage;
  appBootstrapUnit = config.systemd.user.services.demo-app-bootstrap;
  appReconcileUnit = config.systemd.user.services.demo-app-reconcile;
  appVerifyUnit = config.systemd.user.services.demo-app-verify;
  appReadyTarget = config.systemd.user.targets.demo-app-ready;
  testerManagedTarget = config.systemd.user.targets.tester-managed;
  testerManagedReadyTarget = config.systemd.user.targets.tester-managed-ready;
  rootManagedTarget = config.systemd.user.targets.root-managed;
  rootManagedReadyTarget = config.systemd.user.targets.root-managed-ready;
  restartPolicyVerifyUnit = config.systemd.user.services.demo-restart-policy-verify;
  recreatePolicyVerifyUnit = config.systemd.user.services.demo-recreate-policy-verify;
  imagePullUnit = config.systemd.user.services.demo-app-image-pull;
  rootlessMigrateUnit = config.systemd.user.services.podman-rootless-idmap-migrate-tester;
  rootlessMigrateScript =
    builtins.readFile (builtins.head (lib.splitString " " rootlessMigrateUnit.serviceConfig.ExecStart));

  failedAssertions = builtins.filter (assertion: ! assertion.assertion) config.assertions;

  imagePullPlanEntryByService = serviceName: let
    matches = builtins.filter (entry: entry.serviceName == serviceName) imagePullPlan;
  in
    assert builtins.length matches == 1;
      builtins.head matches;

  metadataPathFromEnv = env: let
    prefix = "NIX_PODMAN_COMPOSE_METADATA=";
    matches = builtins.filter (entry: lib.hasPrefix prefix entry) env;
  in
    assert builtins.length matches == 1;
      lib.removePrefix prefix (builtins.head matches);

  metadataFromUnit = unit:
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile (metadataPathFromEnv unit.serviceConfig.Environment)));

  appMetadata = metadataFromUnit appUnit;
  dbMetadata = metadataFromUnit dbUnit;
  textSourceMetadata = metadataFromUnit textSourceUnit;
  fileSourceMetadata = metadataFromUnit fileSourceUnit;
  opaqueSecretMetadata = metadataFromUnit opaqueSecretUnit;
  jobMetadata = metadataFromUnit jobUnit;
  restartPolicyMetadata = metadataFromUnit config.systemd.user.services.demo-restart-policy;
  recreatePolicyMetadata = metadataFromUnit config.systemd.user.services.demo-recreate-policy;

  entryByDst = dst: entries: let
    matches = builtins.filter (entry: entry.dst == dst) entries;
  in
    assert builtins.length matches == 1;
      builtins.head matches;

  entryByBaseName = baseName: entries: let
    matches = builtins.filter (entry: builtins.baseNameOf entry.dst == baseName) entries;
  in
    assert builtins.length matches == 1;
      builtins.head matches;

  appComposeFiles = appMetadata.composeFiles;
  appPullComposeFiles = appMetadata.pullComposeFiles;
  appStagedDsts = map (entry: entry.dst) appMetadata.stagedFiles;
  appReloadDsts = map (entry: entry.dst) appMetadata.reload.stagedFiles;
  appEnvSecret = entryByBaseName "web.env" appMetadata.envSecretFiles;
  appFileSecret = entryByBaseName "db-password" appMetadata.stagedFiles;
  appReloadDir = entryByDst "/srv/demo/app/reload" appMetadata.reload.dirs;
  appManualRecreate = entryByDst "/srv/demo/app/manual-recreate.txt" appMetadata.stagedFiles;
  appOrdinaryFile = entryByDst "/srv/demo/app/other.txt" appMetadata.stagedFiles;
  appRenderedCompose = builtins.readFile app.sourcePaths."compose.yml";
  textRenderedCompose = builtins.readFile textSource.sourcePaths."compose.yml";
  fileRenderedCompose = builtins.readFile fileSource.sourcePaths."compose.yml";
  opaqueSecretFileSecretOverride = builtins.readFile opaqueSecret.sourcePaths."__podman-file-secrets.override.yml";
  controlRegistry = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile config.system.build.podmanComposeControlRegistry));
  imagePullPlan = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile config.system.build.podmanComposeImagePullPlan));
  appImagePullPlanEntry = imagePullPlanEntryByService "demo-app";
  jobImagePullPlanEntry = imagePullPlanEntryByService "demo-custom-job";
in
  assert failedAssertions == [];
  assert stack.user == "tester";
  assert app.user == null;
  assert app.resolvedWorkingDir == "/srv/demo/app";
  assert app.reconcilePolicy == "auto";
  assert app.removalPolicy == "delete";
  assert app.autoStart == true;
  assert app.longRunning == false;
  assert app.startStateStallSeconds == 75;
  assert app.knownSourceComposeServices == ["web" "worker"];
  assert db.resolvedWorkingDir == "/srv/demo/db";
  assert textSource.source == sourceInlineText;
  assert textSource.resolvedWorkingDir == "/srv/demo/text-source";
  assert textSource.knownSourceComposeServices == ["text"];
  assert fileSource.source == sourceFile;
  assert fileSource.resolvedWorkingDir == "/srv/demo/file-source";
  assert fileSource.knownSourceComposeServices == ["file"];
  assert opaqueSecret.knownSourceComposeServices == ["opaque-secret"];
  assert opaqueSecretMetadata.expectedComposeServices == ["opaque-secret"];
  assert builtins.elem "/srv/demo/opaque-secret/__podman-file-secrets.override.yml" opaqueSecretMetadata.composeFiles;
  assert lib.hasInfix ''"opaque-secret"'' opaqueSecretFileSecretOverride;
  assert lib.hasInfix "/run/secrets/default-token" opaqueSecretFileSecretOverride;
  assert job.user == "root";
  assert job.serviceName == "demo-custom-job";
  assert job.autoStart == false;
  assert job.removalPolicy == "keep";
  assert config.networking.firewall.allowedTCPPorts == [18080];
  assert config.networking.firewall.allowedUDPPorts == [1053];
  assert stack.tunnelIngress.cloudflare
  == {
    "app.example.test" = "http://127.0.0.1:18082";
  };
  assert stack.tunnelIngress.rathole
  == {
    "app-rathole.example.test" = "http://127.0.0.1:18083";
  };
  assert builtins.length stack.tunnelEndpoints == 2;
  assert (builtins.head (builtins.filter (endpoint: endpoint.name == "app-rathole") stack.tunnelEndpoints)).remotePort == 443;
  assert appUnit.wantedBy == ["tester-managed.target"];
  assert appUnit.restartIfChanged == true;
  assert appUnit.stopIfChanged == true;
  assert builtins.elem appMetadata.restartStamp appUnit.restartTriggers;
  assert builtins.elem app.bootTag appUnit.restartTriggers;
  assert builtins.elem appMetadata.recreateStamp appUnit.restartTriggers;
  assert builtins.elem app.recreateTag appUnit.restartTriggers;
  assert builtins.elem app.reloadTag appUnit.reloadTriggers;
  assert builtins.length appUnit.reloadTriggers == 2;
  assert jobUnit.wantedBy == [];
  assert jobUnit.restartIfChanged == false;
  assert jobUnit.stopIfChanged == false;
  assert builtins.elem "demo-app-stage.service" appUnit.after;
  assert builtins.elem "demo-app-bootstrap.service" appUnit.after;
  assert builtins.elem "demo-db-ready.target" appUnit.after;
  assert builtins.elem "demo-optional-ready.target" appUnit.after;
  assert builtins.elem "external-ready.service" appUnit.after;
  assert builtins.elem "network-online.target" appUnit.after;
  assert builtins.elem "podman-rootless-idmap-migrate-tester.service" appUnit.after;
  assert appUnit.unitConfig.Requires
  == [
    "podman-rootless-idmap-migrate-tester.service"
    "demo-app-stage.service"
    "demo-app-bootstrap.service"
    "demo-db-ready.target"
    "external-ready.service"
    "demo-app-image-pull.service"
  ];
  assert builtins.elem "network-online.target" appUnit.wants;
  assert builtins.elem "demo-optional-ready.target" appUnit.wants;
  assert textSourceUnit.serviceConfig.WorkingDirectory == "-/srv/demo/text-source";
  assert fileSourceUnit.serviceConfig.WorkingDirectory == "-/srv/demo/file-source";
  assert appUnit.unitConfig.ConditionUser == "tester";
  assert appUnit.serviceConfig.Type == "notify";
  assert appUnit.serviceConfig.NotifyAccess == "all";
  assert appUnit.serviceConfig.WorkingDirectory == "-/srv/demo/app";
  assert lib.hasSuffix " start-staged" appUnit.serviceConfig.ExecStart;
  assert lib.hasSuffix " stop" appUnit.serviceConfig.ExecStop;
  assert lib.hasSuffix " reload" appUnit.serviceConfig.ExecReload;
  assert lib.hasSuffix " post-stop" appUnit.serviceConfig.ExecStopPost;
  assert appUnit.serviceConfig.KillMode == "control-group";
  assert builtins.elem "NIX_PODMAN_COMPOSE_START_STATE_STALL_SECONDS=75" appUnit.serviceConfig.Environment;
  assert appUnit.serviceConfig.TimeoutStartSec == 120;
  assert !(builtins.hasAttr "demo-app-start-worker" config.systemd.user.services);
  assert !(builtins.hasAttr "demo-db-start-worker" config.systemd.user.services);
  assert dbMetadata.longRunning == true;
  assert dbMetadata.startWorkerUnit == "";
  assert appUnit.serviceConfig.RestartPreventExitStatus == "75";
  assert appStageUnit.serviceConfig.Type == "oneshot";
  assert appStageUnit.unitConfig.ConditionUser == "tester";
  assert appStageUnit.unitConfig.Requires == ["podman-rootless-idmap-migrate-tester.service"];
  assert lib.hasSuffix " stage" appStageUnit.serviceConfig.ExecStart;
  assert appBootstrapUnit.unitConfig.Requires == ["demo-app-stage.service"];
  assert lib.hasSuffix " bootstrap" appBootstrapUnit.serviceConfig.ExecStart;
  assert appReconcileUnit.unitConfig.Requires == ["demo-app.service"];
  assert lib.hasSuffix " reconcile" appReconcileUnit.serviceConfig.ExecStart;
  assert appVerifyUnit.unitConfig.Requires
  == [
    "demo-app.service"
    "demo-app-reconcile.service"
  ];
  assert lib.hasSuffix " verify" appVerifyUnit.serviceConfig.ExecStart;
  assert appReadyTarget.unitConfig.ConditionUser == "tester";
  assert appReadyTarget.unitConfig."X-StopOnReconfiguration" == true;
  assert appReadyTarget.unitConfig.Requires == ["demo-app-verify.service"];
  assert testerManagedTarget.wantedBy == ["default.target"];
  assert builtins.elem "demo-app.service" testerManagedTarget.wants;
  assert testerManagedReadyTarget.wantedBy == ["default.target"];
  assert builtins.elem "demo-app-ready.target" testerManagedReadyTarget.unitConfig.Requires;
  assert rootManagedTarget.wantedBy == [];
  assert rootManagedReadyTarget.wantedBy == [];
  assert imagePullUnit.serviceConfig.Type == "oneshot";
  assert imagePullUnit.unitConfig.ConditionUser == "tester";
  assert lib.hasSuffix " image-pull" imagePullUnit.serviceConfig.ExecStart;
  assert rootlessMigrateUnit.unitConfig.ConditionUser == "tester";
  assert lib.hasInfix ".config/containers/storage.conf" rootlessMigrateScript;
  assert lib.hasInfix "mount_program" rootlessMigrateScript;
  assert config.users.manageLingering == true;
  assert config.users.users.tester.linger == true;
  assert builtins.length imagePullPlan == 8;
  assert appImagePullPlanEntry.user == "tester";
  assert appImagePullPlanEntry.uid == "1234";
  assert appImagePullPlanEntry.serviceName == "demo-app";
  assert appImagePullPlanEntry.metadataFile == metadataPathFromEnv appUnit.serviceConfig.Environment;
  assert appImagePullPlanEntry.imageTag == "image-1";
  assert lib.hasSuffix "/bin/podman-compose-helper" appImagePullPlanEntry.helper;
  assert controlRegistry.demo-app.timeoutReadySeconds == 45;
  assert controlRegistry.demo-db.timeoutReadySeconds == 45;
  assert controlRegistry.demo-custom-job.timeoutReadySeconds == 45;
  assert controlRegistry.demo-app.metadataFile == metadataPathFromEnv appUnit.serviceConfig.Environment;
  assert jobImagePullPlanEntry.user == "root";
  assert jobImagePullPlanEntry.uid == "0";
  assert jobImagePullPlanEntry.metadataFile == metadataPathFromEnv jobUnit.serviceConfig.Environment;
  assert jobImagePullPlanEntry.imageTag == "0";
  assert lib.hasSuffix "/bin/podman-compose-helper" jobImagePullPlanEntry.helper;
  assert appMetadata.version == 10;
  assert appMetadata.serviceName == "demo-app";
  assert appMetadata.workingDir == "/srv/demo/app";
  assert appMetadata.state == "running";
  assert appMetadata.reconcilePolicy == "auto";
  assert appMetadata.removalPolicy == "delete";
  assert appMetadata.longRunning == false;
  assert appMetadata.startWorkerUnit == "";
  assert appMetadata.restartStamp != "";
  assert appMetadata.recreateStamp != "";
  assert appMetadata.recreateClassStamp != "";
  assert appMetadata.recreateStamp == appMetadata.recreateClassStamp;
  assert appMetadata.composeArgs == ["--project-name" "demo-app"];
  assert appMetadata.preStart == ["printf start"];
  assert appMetadata.postStart == ["printf post"];
  assert appMetadata.preStop == ["-printf stop"];
  assert appMetadata.expectedComposeServices == ["web" "worker"];
  assert lib.hasInfix "docker.io/library/nginx:latest" appRenderedCompose;
  assert lib.hasInfix "docker.io/library/busybox:latest" appRenderedCompose;
  assert builtins.length appComposeFiles == 3;
  assert builtins.elem "/srv/demo/app/compose.yml" appComposeFiles;
  assert builtins.elem "/srv/demo/app/__podman-env-secrets.override.yml" appComposeFiles;
  assert builtins.elem "/srv/demo/app/__podman-file-secrets.override.yml" appComposeFiles;
  assert appPullComposeFiles != appComposeFiles;
  assert builtins.length appPullComposeFiles == 1;
  assert lib.hasSuffix "-compose_yml" (builtins.head appPullComposeFiles);
  assert builtins.elem "/srv/demo/app/compose.yml" appStagedDsts;
  assert builtins.elem "/srv/demo/app/config/app.yml" appStagedDsts;
  assert builtins.elem "/srv/demo/app/reload/web.conf" appStagedDsts;
  assert builtins.elem "/srv/demo/app/external-reload.txt" appStagedDsts;
  assert builtins.elem "/srv/demo/app/manual-recreate.txt" appStagedDsts;
  assert builtins.elem "/srv/demo/app/other.txt" appStagedDsts;
  assert builtins.elem "/srv/demo/app/__podman-env-secrets.override.yml" appStagedDsts;
  assert builtins.elem "/srv/demo/app/__podman-file-secrets.override.yml" appStagedDsts;
  assert appManualRecreate.mode == "none";
  assert appFileSecret.src == "/run/secrets/db-password";
  assert appFileSecret.mode == "0400";
  assert appFileSecret.dstDir == "/srv/demo/app/.podman-compose/file-secrets";
  assert appEnvSecret.dst == "/srv/demo/app/.podman-compose/env-secrets/web.env";
  assert appEnvSecret.dstDir == "/srv/demo/app/.podman-compose/env-secrets";
  assert appEnvSecret.entries
  == [
    {
      name = "APP_TOKEN";
      src = "/run/secrets/app-token";
    }
  ];
  assert appMetadata.reload.method == "signal";
  assert appMetadata.reload.signal == "USR1";
  assert appMetadata.reload.services == ["web"];
  assert appReloadDir.mode == "0750";
  assert appReloadDir.user == "1000";
  assert appReloadDir.group == "1000";
  assert appReloadDir.scope == "container";
  assert appReloadDsts
  == [
    "/srv/demo/app/external-reload.txt"
    "/srv/demo/app/reload/web.conf"
  ];
  assert appOrdinaryFile.dst == "/srv/demo/app/other.txt";
  assert !(builtins.elem appOrdinaryFile.dst appReloadDsts);
  assert textSourceMetadata.serviceName == "demo-text-source";
  assert textSourceMetadata.workingDir == "/srv/demo/text-source";
  assert textSourceMetadata.expectedComposeServices == ["text"];
  assert textSourceMetadata.composeArgs == [];
  assert textSourceMetadata.composeFiles == ["/srv/demo/text-source/compose.yml"];
  assert textSourceMetadata.pullComposeFiles != textSourceMetadata.composeFiles;
  assert textRenderedCompose == sourceInlineText;
  assert fileSourceMetadata.serviceName == "demo-file-source";
  assert fileSourceMetadata.workingDir == "/srv/demo/file-source";
  assert fileSourceMetadata.expectedComposeServices == ["file"];
  assert fileSourceMetadata.composeFiles == ["/srv/demo/file-source/compose.yml"];
  assert fileSourceMetadata.pullComposeFiles != fileSourceMetadata.composeFiles;
  assert fileRenderedCompose == builtins.readFile sourceFile;
  assert jobMetadata.state == "stopped";
  assert jobMetadata.removalPolicy == "keep";
  assert jobMetadata.longRunning == false;
  assert restartPolicy.reconcilePolicy == "restart";
  assert restartPolicyMetadata.reconcilePolicy == "restart";
  assert restartPolicyMetadata.restartStamp != "";
  assert restartPolicyMetadata.recreateStamp == restartPolicyMetadata.recreateClassStamp;
  assert restartPolicyVerifyUnit.unitConfig.Requires == ["demo-restart-policy.service"];
  assert recreatePolicy.reconcilePolicy == "recreate";
  assert recreatePolicyMetadata.reconcilePolicy == "recreate";
  assert recreatePolicyMetadata.restartStamp != "";
  assert recreatePolicyMetadata.recreateClassStamp != "";
  assert recreatePolicyMetadata.recreateStamp != recreatePolicyMetadata.recreateClassStamp;
  assert recreatePolicyVerifyUnit.unitConfig.Requires == ["demo-recreate-policy.service"];
    pkgs.runCommand "podman-compose-module-test" {} ''
      touch "$out"
    ''
