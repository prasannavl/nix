{pkgs}: let
  lib = pkgs.lib;
  sourceAttrs = import ./examples/source-attrs.nix;
  sourceInlineText = import ./examples/source-inline-text.nix;
  sourceFile = ./examples/source-file.compose.yml;
  localImageTar = pkgs.runCommand "local-image.tar" {} ''
    touch "$out"
  '';
  localImagePackage =
    localImageTar
    // {
      passthru.imageRef = "localhost/demo/package:1";
    };
  localImageSourceRef = "localhost/demo/local:1";
  localImageStoreHash =
    builtins.substring 0 12 (builtins.baseNameOf (builtins.unsafeDiscardStringContext (toString localImageTar)));
  localImageRuntimeRef = "${localImageSourceRef}-nix-${localImageStoreHash}";
  localImagePackageRuntimeRef = "localhost/demo/package:1-nix-${localImageStoreHash}";
  localImageStoreRef = "nix-store:${localImageTar}";
  localImageStoreRuntimeRef = "localhost/nix-local/image:${localImageStoreHash}";
  testCaSourceHash = builtins.hashString "sha256" (builtins.toJSON [
    (builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (toString sourceFile)))
    (builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (toString localImageTar)))
  ]);

  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    modules = [
      ../default.nix
      ../../services/abird-host-agent
      {
        system.stateVersion = "26.05";
        networking.hostName = "podman-compose-test";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };

        users = {
          users = {
            tester = {
              isNormalUser = true;
              uid = 1234;
              group = "tester";
              home = "/home/tester";
            };
            laner = {
              isNormalUser = true;
              uid = 1235;
              group = "laner";
              home = "/home/laner";
            };
          };
          groups = {
            tester.gid = 1234;
            laner.gid = 1235;
          };
        };

        systemd.user.services.external-ready = {
          unitConfig.ConditionUser = "tester";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        services = {
          abird-host-agent.enable = true;

          podman-compose = {
            demo = {
              backend = "compose";
              user = "tester";
              stackDir = "/srv/demo";
              servicePrefix = "demo-";
              reconcilePolicy = "auto";
              removalPolicy = "delete";
              autoStart = true;
              startConcurrency = 2;
              timeoutReadySeconds = 45;
              timeoutBootstrapSeconds = 180;

              instances = {
                app = {...}: {
                  source = sourceAttrs;
                  composeArgs = ["--project-name" "demo-app"];
                  dependsOn = ["db" "external-ready.service"];
                  wants = ["optional"];
                  waitForNetwork = true;
                  longRunning = false;
                  composeUpNoProgressSeconds = 75;
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
                  trustedCaCertificates."test-ca" = {
                    file = "/run/secrets/test-ca";
                    sourceHashInputs = [sourceFile localImageTar];
                    services = ["web"];
                    envVars = [];
                  };
                };

                db = {
                  source.services.db.image = "docker.io/library/postgres:latest";
                  exposedPorts.http.port = 15432;
                  verifyCommand = ["${pkgs.coreutils}/bin/true"];
                };

                "text-source".source = sourceInlineText;

                "file-source".source = sourceFile;

                extended = {
                  startPriority = -50;
                  source = ''
                    services:
                      web:
                        image: docker.io/library/nginx:latest
                        extends:
                          file: sidecar.yml
                          service: base
                  '';
                  files."sidecar.yml".text = ''
                    services:
                      base:
                        environment:
                          FROM_SIDECAR: "1"
                  '';
                };

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

                "local-image" = {
                  source.services.local.image = localImageSourceRef;
                  localImages.${localImageSourceRef} = localImageTar;
                };

                "local-image-package" = {
                  source.services.local.image = localImagePackage;
                };

                "local-image-store" = {
                  source = ''
                    services:
                      local:
                        image: ${localImageStoreRef}
                  '';
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

                native = {
                  backend = "quadlet";
                  exposedPorts.http = {
                    port = 18081;
                    upstreamProtocol = "https";
                    upstreamHost = "native.example.test";
                    upstreamTlsName = "native.example.test";
                  };
                  source.services.web = {
                    image = "docker.io/library/busybox:latest";
                    command = ["printf" "%s" "$$HOME" "100%"];
                    environment = {
                      MESSAGE = "hello world";
                      ENABLED = true;
                    };
                    env_file = ["./app.env"];
                    ports = ["127.0.0.1:18081:8080"];
                    restart = "always";
                    volumes = ["./data:/data:ro"];
                    working_dir = "/data";
                  };
                  dirs.data = {};
                  files."app.env".text = "TOKEN=test\n";
                  preStart = ["printf native-start"];
                  preStop = ["-printf native-stop"];
                };
              };
            };

            lane = {
              user = "laner";
              stackDir = "/srv/lane";
              servicePrefix = "lane-";
              startConcurrency = 4;
              instances = {
                consumer = {
                  startPriority = -100;
                  source.services.consumer.image = "docker.io/library/busybox:latest";
                  dependsOn = ["provider5"];
                };
                provider1.source.services.provider1.image = "docker.io/library/busybox:latest";
                provider2.source.services.provider2.image = "docker.io/library/busybox:latest";
                provider3.source.services.provider3.image = "docker.io/library/busybox:latest";
                provider4.source.services.provider4.image = "docker.io/library/busybox:latest";
                provider5 = {
                  startPriority = -50;
                  source.services.provider5.image = "docker.io/library/busybox:latest";
                };
              };
            };

            inherited = {
              backend = "quadlet";
              user = "tester";
              stackDir = "/srv/inherited";
              servicePrefix = "inherited-";
              instances.worker.source.services.worker = {
                image = "docker.io/library/busybox:latest";
                command = ["true"];
              };
            };
          };
        };
      }
    ];
  };

  config = evalConfig.config;
  unlimitedConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.podman-compose.lane.startConcurrency = lib.mkForce (-1);
        }
      ];
    }).config;
  invalidNativePreStopConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.podman-compose.demo.instances.native.preStop = lib.mkForce ["false"];
        }
      ];
    }).config;
  invalidNativePreStopAssertions = builtins.filter (assertion: !assertion.assertion) invalidNativePreStopConfig.assertions;
  quadletOnlyConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.podman-compose = lib.mkForce {
            native = {
              backend = "quadlet";
              user = "tester";
              instances.app.source.services.app.image = "docker.io/library/busybox:latest";
            };
          };
        }
      ];
    }).config;
  stack = config.services.podman-compose.demo;
  laneStack = config.services.podman-compose.lane;
  app = stack.instances.app;
  db = stack.instances.db;
  textSource = stack.instances."text-source";
  fileSource = stack.instances."file-source";
  extended = stack.instances.extended;
  opaqueSecret = stack.instances."opaque-secret";
  localImage = stack.instances."local-image";
  localImagePackageInstance = stack.instances."local-image-package";
  localImageStoreInstance = stack.instances."local-image-store";
  job = stack.instances.job;
  restartPolicy = stack.instances."restart-policy";
  recreatePolicy = stack.instances."recreate-policy";
  native = stack.instances.native;
  inheritedStack = config.services.podman-compose.inherited;
  inheritedNative = inheritedStack.instances.worker;
  unlimitedLaneStack = unlimitedConfig.services.podman-compose.lane;
  appUnit = config.systemd.user.services.demo-app;
  dbUnit = config.systemd.user.services.demo-db;
  textSourceUnit = config.systemd.user.services.demo-text-source;
  fileSourceUnit = config.systemd.user.services.demo-file-source;
  extendedUnit = config.systemd.user.services.demo-extended;
  opaqueSecretUnit = config.systemd.user.services.demo-opaque-secret;
  localImageUnit = config.systemd.user.services.demo-local-image;
  localImagePackageUnit = config.systemd.user.services.demo-local-image-package;
  localImageStoreUnit = config.systemd.user.services.demo-local-image-store;
  jobUnit = config.systemd.user.services.demo-custom-job;
  appStageUnit = config.systemd.user.services.demo-app-stage;
  appReconcileUnit = config.systemd.user.services.demo-app-reconcile;
  appVerifyUnit = config.systemd.user.services.demo-app-verify;
  appReadyTarget = config.systemd.user.targets.demo-app-ready;
  testerManagedTarget = config.systemd.user.targets.tester-managed;
  rootManagedTarget = config.systemd.user.targets.root-managed;
  restartPolicyVerifyUnit = config.systemd.user.services.demo-restart-policy-verify;
  restartPolicyReadyTarget = config.systemd.user.targets.demo-restart-policy-ready;
  recreatePolicyVerifyUnit = config.systemd.user.services.demo-recreate-policy-verify;
  recreatePolicyReadyTarget = config.systemd.user.targets.demo-recreate-policy-ready;
  nativeUnit = config.systemd.user.services.demo-native;
  nativeStageUnit = config.systemd.user.services.demo-native-stage;
  nativeStageCommands = lib.toList nativeStageUnit.serviceConfig.ExecStart;
  nativeVerifyUnit = config.systemd.user.services.demo-native-verify;
  nativeReadyTarget = config.systemd.user.targets.demo-native-ready;
  imagePullUnit = config.systemd.user.services.demo-app-image-pull;
  rootlessMigrateUnit = config.systemd.user.services.podman-rootless-idmap-migrate-tester;
  runtimePreflightUnit = config.systemd.user.services.podman-runtime-preflight-tester;
  appHoldPath = "/var/lib/abird-host-agent/holds/${builtins.hashString "sha256" "service:demo-app"}.json";
  appActivationPath = "/var/lib/abird-host-agent/activation-authorizations/${builtins.hashString "sha256" "service:demo-app"}.json";
  nativeHoldPath = "/var/lib/abird-host-agent/holds/${builtins.hashString "sha256" "service:demo-native"}.json";
  nativeActivationPath = "/var/lib/abird-host-agent/activation-authorizations/${builtins.hashString "sha256" "service:demo-native"}.json";
  hostHoldPath = "/var/lib/abird-host-agent/holds/${builtins.hashString "sha256" "host:podman-compose-test"}.json";
  migrationGateCondition = ["|!${appHoldPath}" "|${appActivationPath}" "!${hostHoldPath}"];
  hasMigrationGateConditions = conditions:
    builtins.length conditions
    == builtins.length migrationGateCondition
    && builtins.all (condition: builtins.elem condition conditions) migrationGateCondition;
  laneConsumer = config.services.podman-compose.lane.instances.consumer;
  laneConsumerUnit = config.systemd.user.services.lane-consumer;
  laneProvider1Unit = config.systemd.user.services.lane-provider1;
  laneProvider3Unit = config.systemd.user.services.lane-provider3;
  laneProvider3StageUnit = config.systemd.user.services.lane-provider3-stage;
  laneProvider4Unit = config.systemd.user.services.lane-provider4;
  laneProvider4StageUnit = config.systemd.user.services.lane-provider4-stage;
  laneProvider5Unit = config.systemd.user.services.lane-provider5;
  unlimitedLaneProvider3Unit = unlimitedConfig.systemd.user.services.lane-provider3;
  unlimitedLaneProvider4Unit = unlimitedConfig.systemd.user.services.lane-provider4;
  rootlessMigrateScriptPath = builtins.head (lib.splitString " " rootlessMigrateUnit.serviceConfig.ExecStart);

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
  runtimePreflightMetadataPathFromEnv = env: let
    prefix = "NIX_PODMAN_COMPOSE_RUNTIME_PREFLIGHT_METADATA=";
    matches = builtins.filter (entry: lib.hasPrefix prefix entry) env;
  in
    assert builtins.length matches == 1;
      lib.removePrefix prefix (builtins.head matches);
  runtimePreflightStorePath = runtimePreflightMetadataPathFromEnv runtimePreflightUnit.serviceConfig.Environment;
  runtimePreflightSource = config.environment.etc."podman-compose/runtime-preflight/tester.json".source;
  runtimePreflightMetadata = runtimePreflightSource.passthru.value;

  controlRegistry = config.system.build.podmanComposeControlRegistry.passthru.value;
  imagePullPlan = config.system.build.podmanComposeImagePullPlan.passthru.value;
  metadataFromUnit = unit: let
    path = metadataPathFromEnv unit.serviceConfig.Environment;
    matches = builtins.filter (
      entry:
        (entry ? metadataFile)
        && entry.metadataFile != null
        && toString entry.metadataFile == path
    ) (lib.attrValues controlRegistry);
  in
    assert builtins.length matches == 1;
      (builtins.head matches).metadataFile.passthru.value;

  appMetadata = metadataFromUnit appUnit;
  dbMetadata = metadataFromUnit dbUnit;
  textSourceMetadata = metadataFromUnit textSourceUnit;
  fileSourceMetadata = metadataFromUnit fileSourceUnit;
  extendedMetadata = metadataFromUnit extendedUnit;
  opaqueSecretMetadata = metadataFromUnit opaqueSecretUnit;
  localImageMetadata = metadataFromUnit localImageUnit;
  localImagePackageMetadata = metadataFromUnit localImagePackageUnit;
  localImageStoreMetadata = metadataFromUnit localImageStoreUnit;
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
  extendedPullDir = builtins.dirOf (builtins.head extendedMetadata.pullComposeFiles);
  systemdUserGraphCheck = config.system.build.podmanComposeSystemdUserGraphCheck;
  quadletGeneratorCheck = config.system.build.podmanComposeQuadletGeneratorCheck;
  appImagePullPlanEntry = imagePullPlanEntryByService "demo-app";
  jobImagePullPlanEntry = imagePullPlanEntryByService "demo-custom-job";
  appGeneratedProbePath = builtins.head controlRegistry.demo-app.verifyCommand;
  nativeGeneratedProbePath = builtins.head native.verifyCommand;
  nativeVerifyScriptPath = nativeVerifyUnit.serviceConfig.ExecStart;
in
  assert failedAssertions == [];
  assert stack.user == "tester";
  assert stack.backend == "compose";
  assert laneStack.backend == "quadlet";
  assert stack.startConcurrency == 2;
  assert inheritedStack.startConcurrency == 4;
  assert unlimitedLaneStack.startConcurrency == -1;
  assert !(builtins.elem "lane-provider5-ready.target" unlimitedLaneProvider3Unit.after);
  assert !(builtins.elem "lane-consumer-ready.target" unlimitedLaneProvider4Unit.after);
  assert app.backend == "compose";
  assert laneConsumer.backend == "quadlet";
  assert inheritedStack.backend == "quadlet";
  assert inheritedNative.backend == "quadlet";
  assert app.user == null;
  assert app.startPriority == 0;
  assert app.resolvedWorkingDir == "/srv/demo/app";
  assert app.reconcilePolicy == "auto";
  assert app.removalPolicy == "delete";
  assert app.autoStart == true;
  assert app.longRunning == false;
  assert app.composeUpNoProgressSeconds == 75;
  assert app.knownSourceComposeServices == ["web" "worker"];
  assert app.fileSecrets."test-ca".sourceHash == testCaSourceHash;
  assert db.resolvedWorkingDir == "/srv/demo/db";
  assert textSource.source == sourceInlineText;
  assert textSource.resolvedWorkingDir == "/srv/demo/text-source";
  assert textSource.knownSourceComposeServices == ["text"];
  assert fileSource.source == sourceFile;
  assert fileSource.resolvedWorkingDir == "/srv/demo/file-source";
  assert fileSource.knownSourceComposeServices == ["file"];
  assert extended.startPriority == -50;
  assert extended.resolvedWorkingDir == "/srv/demo/extended";
  assert extended.knownSourceComposeServices == ["web"];
  assert opaqueSecret.knownSourceComposeServices == ["opaque-secret"];
  assert opaqueSecretMetadata.expectedComposeServices == ["opaque-secret"];
  assert builtins.elem "/srv/demo/opaque-secret/__podman-file-secrets.override.yml" opaqueSecretMetadata.composeFiles;
  assert localImage.declaredImages == [];
  assert localImage.localImageMetadata
  == [
    {
      imageRef = localImageSourceRef;
      imageTar = toString localImageTar;
      loadRef = localImageSourceRef;
      runtimeRef = localImageRuntimeRef;
      storeHash = localImageStoreHash;
    }
  ];
  assert localImageMetadata.localImages == localImage.localImageMetadata;
  assert localImagePackageInstance.declaredImages == [];
  assert localImagePackageInstance.localImageMetadata
  == [
    {
      imageRef = "localhost/demo/package:1";
      imageTar = toString localImageTar;
      loadRef = "localhost/demo/package:1";
      runtimeRef = localImagePackageRuntimeRef;
      storeHash = localImageStoreHash;
    }
  ];
  assert localImagePackageMetadata.localImages == localImagePackageInstance.localImageMetadata;
  assert localImageStoreInstance.declaredImages == [];
  assert localImageStoreInstance.localImageMetadata
  == [
    {
      imageRef = localImageStoreRef;
      imageTar = toString localImageTar;
      loadRef = "";
      runtimeRef = localImageStoreRuntimeRef;
      storeHash = localImageStoreHash;
    }
  ];
  assert localImageStoreMetadata.localImages == localImageStoreInstance.localImageMetadata;
  assert lib.any (lib.hasPrefix "NIX_PODMAN_COMPOSE_LOCAL_IMAGE_CLOSURE=") localImageStoreUnit.serviceConfig.Environment;
  assert job.user == "root";
  assert job.serviceName == "demo-custom-job";
  assert job.autoStart == false;
  assert job.removalPolicy == "keep";
  assert config.networking.firewall.allowedTCPPorts == [18080];
  assert config.networking.firewall.allowedUDPPorts == [1053];
  assert app.exposedPorts.http.upstreamProtocol == "http";
  assert app.exposedPorts.http.protocols == ["tcp"];
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
  assert appUnit.wantedBy == [];
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
  assert !(builtins.elem "demo-app-bootstrap.service" appUnit.after);
  assert builtins.elem "demo-db-ready.target" appUnit.after;
  assert builtins.elem "demo-optional-ready.target" appUnit.after;
  assert builtins.elem "external-ready.service" appUnit.after;
  assert builtins.elem "network-online.target" appUnit.after;
  assert builtins.elem "podman-rootless-idmap-migrate-tester.service" appUnit.after;
  assert builtins.elem "podman-runtime-preflight-tester.service" appUnit.after;
  assert builtins.elem "abird-host-agent-holds-ready.service" appUnit.after;
  assert !(builtins.elem "podman-managed-graph-migrate-tester.service" appUnit.after);
  assert !(builtins.elem "demo-app.service" appUnit.after);
  assert !(builtins.elem "demo-app.service" extendedUnit.after);
  assert !(builtins.elem "demo-extended.service" dbUnit.after);
  assert builtins.elem "demo-extended-ready.target" appUnit.after;
  assert !(builtins.elem "demo-extended.service" appUnit.after);
  assert !(builtins.elem "demo-extended.service" appUnit.unitConfig.Requires);
  assert !(builtins.elem "demo-extended.service" dbUnit.unitConfig.Requires);
  assert appUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "podman-rootless-idmap-migrate-tester.service"
    "podman-runtime-preflight-tester.service"
    "demo-app-stage.service"
    "demo-db-ready.target"
    "external-ready.service"
    "demo-app-image-pull.service"
  ];
  assert builtins.elem "network-online.target" appUnit.wants;
  assert builtins.elem "demo-optional-ready.target" appUnit.wants;
  assert !(builtins.elem "tester-managed.target" appUnit.after);
  assert textSourceUnit.serviceConfig.WorkingDirectory == "-/srv/demo/text-source";
  assert fileSourceUnit.serviceConfig.WorkingDirectory == "-/srv/demo/file-source";
  assert appUnit.unitConfig.ConditionUser == "tester";
  assert appUnit.unitConfig.PartOf == ["tester-managed.target"];
  assert appUnit.serviceConfig.Type == "oneshot";
  assert appUnit.serviceConfig.RemainAfterExit == true;
  assert appUnit.serviceConfig.Restart == "no";
  assert !(builtins.hasAttr "NotifyAccess" appUnit.serviceConfig);
  assert appUnit.serviceConfig.WorkingDirectory == "-/srv/demo/app";
  assert lib.hasSuffix " start-staged" appUnit.serviceConfig.ExecStart;
  assert lib.hasSuffix " stop" appUnit.serviceConfig.ExecStop;
  assert lib.hasSuffix " reload" appUnit.serviceConfig.ExecReload;
  assert lib.hasSuffix " post-stop" appUnit.serviceConfig.ExecStopPost;
  assert appUnit.serviceConfig.ExecStart == "/etc/podman-compose/helpers/podman-compose-helper start-staged";
  assert builtins.hasAttr "podman-compose/helpers/podman-compose-helper" config.environment.etc;
  assert appUnit.serviceConfig.ExecStop == "/etc/podman-compose/helpers/podman-compose-helper stop";
  assert appUnit.serviceConfig.KillMode == "mixed";
  assert builtins.elem "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" appUnit.serviceConfig.Environment;
  assert builtins.elem "NIX_PODMAN_COMPOSE_VERIFY_TRANSITION_WAIT_SECONDS=40" appUnit.serviceConfig.Environment;
  assert builtins.elem "NIX_PODMAN_COMPOSE_PROVIDER_TIMEOUT_SECONDS=45" appUnit.serviceConfig.Environment;
  assert builtins.elem "NIX_PODMAN_COMPOSE_UP_NO_PROGRESS_SECONDS=75" appUnit.serviceConfig.Environment;
  assert hasMigrationGateConditions appUnit.unitConfig.ConditionPathExists;
  assert appUnit.serviceConfig.TimeoutStartSec == 225;
  assert appUnit.serviceConfig.TimeoutStopSec == 240;
  assert !(builtins.hasAttr "demo-app-start-worker" config.systemd.user.services);
  assert !(builtins.hasAttr "demo-db-start-worker" config.systemd.user.services);
  assert dbMetadata.longRunning == true;
  assert dbMetadata.startWorkerUnit == "";
  assert !(builtins.hasAttr "RestartPreventExitStatus" appUnit.serviceConfig);
  assert appStageUnit.serviceConfig.Type == "oneshot";
  assert appStageUnit.unitConfig.ConditionUser == "tester";
  assert appStageUnit.unitConfig.Requires
  == [
    "podman-rootless-idmap-migrate-tester.service"
  ];
  assert lib.hasSuffix " stage" appStageUnit.serviceConfig.ExecStart;
  assert appStageUnit.serviceConfig.TimeoutStartSec == 45;
  assert !(builtins.hasAttr "demo-app-bootstrap" config.systemd.user.services);
  assert appReconcileUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-app.service"
  ];
  assert hasMigrationGateConditions appReconcileUnit.unitConfig.ConditionPathExists;
  assert lib.hasSuffix " reconcile" appReconcileUnit.serviceConfig.ExecStart;
  assert appVerifyUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-app.service"
    "demo-app-reconcile.service"
  ];
  assert hasMigrationGateConditions appVerifyUnit.unitConfig.ConditionPathExists;
  assert lib.hasSuffix " verify" appVerifyUnit.serviceConfig.ExecStart;
  assert appReadyTarget.unitConfig.ConditionUser == "tester";
  assert hasMigrationGateConditions appReadyTarget.unitConfig.ConditionPathExists;
  assert !(builtins.hasAttr "X-StopOnReconfiguration" appReadyTarget.unitConfig);
  assert appReadyTarget.unitConfig.PartOf == ["demo-app.service"];
  assert appReadyTarget.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-app-verify.service"
  ];
  assert appReadyTarget.unitConfig.After
  == [
    "abird-host-agent-holds-ready.service"
    "demo-app-verify.service"
  ];
  assert testerManagedTarget.wantedBy == ["default.target"];
  assert builtins.elem "demo-app-ready.target" testerManagedTarget.wants;
  assert !(builtins.hasAttr "Requires" testerManagedTarget.unitConfig);
  assert !(builtins.hasAttr "DefaultDependencies" testerManagedTarget.unitConfig);
  assert !(builtins.hasAttr "X-Restart-Triggers" testerManagedTarget.unitConfig);
  assert !(builtins.hasAttr "X-StopOnReconfiguration" testerManagedTarget.unitConfig);
  assert rootManagedTarget.wantedBy == [];
  assert !(builtins.hasAttr "tester-managed-ready" config.systemd.user.targets);
  assert !(builtins.hasAttr "root-managed-ready" config.systemd.user.targets);
  assert laneConsumer.startPriority == -100;
  assert builtins.elem "lane-provider5-ready.target" laneConsumerUnit.after;
  assert !(builtins.elem "lane-provider1.service" laneConsumerUnit.after);
  assert !(builtins.elem "lane-provider1.service" laneProvider5Unit.after);
  assert !(builtins.elem "lane-consumer.service" laneProvider5Unit.after);
  assert !(builtins.elem "lane-consumer.service" laneProvider1Unit.after);
  assert builtins.elem "lane-provider5-ready.target" laneProvider3Unit.after;
  assert !(builtins.elem "lane-provider5.service" laneProvider3Unit.after);
  assert !(builtins.elem "lane-provider5-ready.target" laneProvider3StageUnit.after);
  assert !(builtins.elem "lane-provider5.service" laneProvider3StageUnit.after);
  assert builtins.elem "lane-consumer-ready.target" laneProvider4Unit.after;
  assert !(builtins.elem "lane-consumer.service" laneProvider4Unit.after);
  assert !(builtins.elem "lane-consumer-ready.target" laneProvider4StageUnit.after);
  assert !(builtins.elem "lane-consumer.service" laneProvider4StageUnit.after);
  assert imagePullUnit.serviceConfig.Type == "oneshot";
  assert imagePullUnit.unitConfig.ConditionUser == "tester";
  assert imagePullUnit.unitConfig.Requires
  == [
    "podman-runtime-preflight-tester.service"
  ];
  assert builtins.elem "podman-runtime-preflight-tester.service" imagePullUnit.after;
  assert builtins.elem "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" imagePullUnit.serviceConfig.Environment;
  assert lib.hasSuffix " image-pull" imagePullUnit.serviceConfig.ExecStart;
  assert rootlessMigrateUnit.reloadIfChanged == true;
  assert rootlessMigrateUnit.restartTriggers == [];
  assert builtins.length rootlessMigrateUnit.reloadTriggers == 2;
  assert builtins.elem
  (builtins.head (lib.splitString "/bin/" rootlessMigrateUnit.serviceConfig.ExecStart))
  (map toString rootlessMigrateUnit.reloadTriggers);
  assert rootlessMigrateUnit.serviceConfig.RemainAfterExit == true;
  assert lib.hasSuffix
  " rootless-idmap-reconcile tester /home/tester tester-managed.target"
  rootlessMigrateUnit.serviceConfig.ExecReload;
  assert builtins.elem "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" rootlessMigrateUnit.serviceConfig.Environment;
  assert rootlessMigrateUnit.unitConfig.ConditionUser == "tester";
  assert runtimePreflightUnit.unitConfig.ConditionUser == "tester";
  assert runtimePreflightUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "podman-rootless-idmap-migrate-tester.service"
  ];
  assert builtins.elem "podman-rootless-idmap-migrate-tester.service" runtimePreflightUnit.after;
  assert runtimePreflightUnit.serviceConfig.Type == "oneshot";
  assert runtimePreflightUnit.serviceConfig.RemainAfterExit == false;
  assert runtimePreflightUnit.serviceConfig.TimeoutStartSec == 300;
  assert lib.hasSuffix " runtime-preflight" runtimePreflightUnit.serviceConfig.ExecStart;
  assert runtimePreflightUnit.serviceConfig.ExecStart == "/etc/podman-compose/helpers/podman-compose-helper runtime-preflight";
  assert builtins.elem (builtins.head migrationGateCondition) runtimePreflightUnit.unitConfig.ConditionPathExists;
  assert !(appStageUnit.unitConfig ? ConditionPathExists);
  assert !(imagePullUnit.unitConfig ? ConditionPathExists);
  assert runtimePreflightMetadata.version == 1;
  assert runtimePreflightMetadata.user == "tester";
  assert builtins.length runtimePreflightMetadata.services == 11;
  assert builtins.all (entry: !(entry ? backend)) runtimePreflightMetadata.services;
  assert builtins.any (entry: entry.serviceName == "demo-app") runtimePreflightMetadata.services;
  assert !(builtins.any (entry: entry.serviceName == "demo-native") runtimePreflightMetadata.services);
  assert !(builtins.any (entry: entry.serviceName == "inherited-worker") runtimePreflightMetadata.services);
  assert !(builtins.hasAttr "podman-managed-graph-migrate-tester" config.systemd.user.services);
  assert runtimePreflightMetadataPathFromEnv appUnit.serviceConfig.Environment
  == "/etc/podman-compose/runtime-preflight/tester.json";
  assert runtimePreflightMetadataPathFromEnv appUnit.serviceConfig.Environment != runtimePreflightStorePath;
  assert toString config.environment.etc."podman-compose/runtime-preflight/tester.json".source == runtimePreflightStorePath;
  assert appReconcileUnit.serviceConfig.TimeoutStartSec == 45;
  assert appVerifyUnit.serviceConfig.TimeoutStartSec == 45;
  assert config.users.manageLingering == true;
  assert config.users.users.tester.linger == true;
  assert builtins.length imagePullPlan == 9;
  assert builtins.all (entry: lib.hasPrefix "demo-" entry.serviceName) imagePullPlan;
  assert builtins.filter (entry: entry.serviceName == "demo-local-image") imagePullPlan == [];
  assert builtins.filter (entry: entry.serviceName == "demo-local-image-package") imagePullPlan == [];
  assert builtins.filter (entry: entry.serviceName == "demo-local-image-store") imagePullPlan == [];
  assert builtins.filter (entry: entry.serviceName == "demo-native") imagePullPlan == [];
  assert builtins.filter (entry: entry.serviceName == "inherited-worker") imagePullPlan == [];
  assert appImagePullPlanEntry.user == "tester";
  assert appImagePullPlanEntry.uid == "1234";
  assert appImagePullPlanEntry.serviceName == "demo-app";
  assert toString appImagePullPlanEntry.metadataFile == metadataPathFromEnv appUnit.serviceConfig.Environment;
  assert toString appImagePullPlanEntry.runtimePreflightMetadata == runtimePreflightStorePath;
  assert appImagePullPlanEntry.imageTag == "image-1";
  assert lib.hasSuffix "/bin/podman-compose-helper" appImagePullPlanEntry.helper;
  assert appMetadata.imagePullStamp != "";
  assert controlRegistry.demo-app.timeoutReadySeconds == 45;
  assert controlRegistry.demo-app.unit == "demo-app.service";
  assert controlRegistry.demo-app.readyUnit == "demo-app-ready.target";
  assert controlRegistry.demo-app.managedUnit == "tester-managed.target";
  assert builtins.stringLength controlRegistry.demo-app.drainStamp == 64;
  assert controlRegistry.demo-app.removalPolicy == "delete";
  assert builtins.length controlRegistry.demo-app.verifyCommand == 1;
  assert controlRegistry.demo-app.autoStart == true;
  assert controlRegistry.demo-app.state == "running";
  assert controlRegistry.demo-custom-job.autoStart == false;
  assert controlRegistry.demo-custom-job.state == "stopped";
  assert controlRegistry.demo-db.timeoutReadySeconds == 45;
  assert controlRegistry.demo-db.verifyCommand == ["${pkgs.coreutils}/bin/true"];
  assert controlRegistry.demo-text-source.verifyCommand == [];
  assert controlRegistry.demo-custom-job.timeoutReadySeconds == 45;
  assert toString controlRegistry.demo-app.metadataFile == metadataPathFromEnv appUnit.serviceConfig.Environment;
  assert jobImagePullPlanEntry.user == "root";
  assert jobImagePullPlanEntry.uid == "0";
  assert toString jobImagePullPlanEntry.metadataFile == metadataPathFromEnv jobUnit.serviceConfig.Environment;
  assert jobImagePullPlanEntry.runtimePreflightMetadata == null;
  assert jobImagePullPlanEntry.imageTag == "0";
  assert lib.hasSuffix "/bin/podman-compose-helper" jobImagePullPlanEntry.helper;
  assert jobMetadata.imagePullStamp != "";
  assert appMetadata.version == 11;
  assert !(appMetadata ? backend);
  assert !(appMetadata ? backendData);
  assert appMetadata.timeoutBootstrapSeconds == 180;
  assert appMetadata.verifyCommand == controlRegistry.demo-app.verifyCommand;
  assert appMetadata.serviceName == "demo-app";
  assert appMetadata.workingDir == "/srv/demo/app";
  assert appMetadata.state == "running";
  assert appMetadata.reconcilePolicy == "auto";
  assert appMetadata.removalPolicy == "delete";
  assert appMetadata.longRunning == false;
  assert appMetadata.timeoutReadySeconds == 45;
  assert appMetadata.composeUpNoProgressSeconds == 75;
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
  assert appMetadata.declaredImages == ["docker.io/library/nginx:latest" "docker.io/library/busybox:latest"];
  assert builtins.length appComposeFiles == 3;
  assert builtins.elem "/srv/demo/app/compose.yml" appComposeFiles;
  assert builtins.elem "/srv/demo/app/__podman-env-secrets.override.yml" appComposeFiles;
  assert builtins.elem "/srv/demo/app/__podman-file-secrets.override.yml" appComposeFiles;
  assert appPullComposeFiles != appComposeFiles;
  assert builtins.length appPullComposeFiles == 1;
  assert lib.hasSuffix "/compose.yml" (builtins.head appPullComposeFiles);
  assert lib.hasPrefix (builtins.dirOf (builtins.head appPullComposeFiles)) app.pullSourcePaths."config/app.yml";
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
  assert textSourceMetadata.declaredImages == ["docker.io/library/busybox:latest"];
  assert textSourceMetadata.composeArgs == [];
  assert textSourceMetadata.composeFiles == ["/srv/demo/text-source/compose.yml"];
  assert textSourceMetadata.pullComposeFiles != textSourceMetadata.composeFiles;
  assert fileSourceMetadata.serviceName == "demo-file-source";
  assert fileSourceMetadata.workingDir == "/srv/demo/file-source";
  assert fileSourceMetadata.expectedComposeServices == ["file"];
  assert fileSourceMetadata.declaredImages == ["docker.io/library/busybox:latest"];
  assert fileSourceMetadata.composeFiles == ["/srv/demo/file-source/compose.yml"];
  assert fileSourceMetadata.pullComposeFiles != fileSourceMetadata.composeFiles;
  assert extendedMetadata.expectedComposeServices == ["web"];
  assert extendedMetadata.composeFiles == ["/srv/demo/extended/compose.yml"];
  assert extendedMetadata.pullComposeFiles == [extended.pullSourcePaths."compose.yml"];
  assert lib.hasPrefix extendedPullDir extended.pullSourcePaths."sidecar.yml";
  assert jobMetadata.state == "stopped";
  assert jobMetadata.removalPolicy == "keep";
  assert jobMetadata.longRunning == false;
  assert restartPolicy.reconcilePolicy == "restart";
  assert restartPolicyMetadata.reconcilePolicy == "restart";
  assert restartPolicyMetadata.restartStamp != "";
  assert restartPolicyMetadata.recreateStamp == restartPolicyMetadata.recreateClassStamp;
  assert restartPolicyVerifyUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-restart-policy.service"
  ];
  assert restartPolicyReadyTarget.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-restart-policy-verify.service"
  ];
  assert recreatePolicy.reconcilePolicy == "recreate";
  assert recreatePolicyMetadata.reconcilePolicy == "recreate";
  assert recreatePolicyMetadata.restartStamp != "";
  assert recreatePolicyMetadata.recreateClassStamp != "";
  assert recreatePolicyMetadata.recreateStamp != recreatePolicyMetadata.recreateClassStamp;
  assert recreatePolicyVerifyUnit.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-recreate-policy.service"
  ];
  assert recreatePolicyReadyTarget.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-recreate-policy-verify.service"
  ];
  assert native.backend == "quadlet";
  assert native.nativeBundle != null;
  assert nativeUnit.wantedBy == [];
  assert nativeUnit.unitConfig.PartOf == ["tester-managed.target"];
  assert nativeUnit.serviceConfig.Type == "oneshot";
  assert nativeUnit.serviceConfig.Restart == "no";
  assert !(nativeUnit.serviceConfig ? Environment);
  assert lib.hasSuffix "/bin/true" nativeUnit.serviceConfig.ExecStart;
  assert lib.hasInfix "/bin/podman-quadlet-helper hook pre-stop " nativeUnit.serviceConfig.ExecStop;
  assert !(nativeUnit.serviceConfig ? ExecReload);
  assert builtins.elem "demo-native-stage.service" nativeUnit.unitConfig.Requires;
  assert builtins.elem "podman-rootless-idmap-migrate-tester.service" nativeUnit.unitConfig.Requires;
  assert !(builtins.elem "podman-runtime-preflight-tester.service" nativeUnit.unitConfig.Requires);
  assert !(builtins.hasAttr "demo-native-image-pull" config.systemd.user.services);
  assert nativeStageUnit.serviceConfig.Type == "oneshot";
  assert nativeStageUnit.serviceConfig.RemainAfterExit == true;
  assert nativeStageUnit.serviceConfig.TimeoutStartSec == 180;
  assert nativeStageUnit.unitConfig.StopWhenUnneeded == true;
  assert lib.hasInfix "/bin/podman-quadlet-helper stage init " (builtins.head nativeStageCommands);
  assert builtins.any
  (command: lib.hasInfix (builtins.unsafeDiscardStringContext native.pullSourcePaths."app.env") command)
  nativeStageCommands;
  assert builtins.all (command:
    lib.hasInfix "/bin/podman-quadlet-helper stage " command
    || lib.hasInfix "/bin/podman-quadlet-helper hook pre-start " command)
  nativeStageCommands;
  assert !(nativeStageUnit.serviceConfig ? ExecStop);
  assert lib.hasInfix "/bin/podman-quadlet-helper stage cleanup " nativeStageUnit.serviceConfig.ExecStopPost;
  assert nativeStageUnit.unitConfig.PartOf == ["demo-native.service"];
  assert nativeVerifyUnit.unitConfig.Requisite == ["demo-native.service"];
  assert nativeVerifyUnit.unitConfig.Requires == "abird-host-agent-holds-ready.service";
  assert nativeReadyTarget.unitConfig.Requires
  == [
    "abird-host-agent-holds-ready.service"
    "demo-native-verify.service"
    "demo-native.service"
  ];
  assert appUnit.serviceConfig.ExecStart == "/etc/podman-compose/helpers/podman-compose-helper start-staged";
  assert lib.hasSuffix
  "/bin/podman-compose-helper"
  (toString quadletOnlyConfig.environment.etc."podman-compose/helpers/podman-compose-helper".source);
  assert lib.hasInfix "/bin/podman-composectl" config.system.activationScripts.podman-compose-drain-changed.text;
  assert lib.hasInfix "drain-changed" config.system.activationScripts.podman-compose-drain-changed.text;
  assert controlRegistry.demo-native.backend == "quadlet";
  assert controlRegistry.demo-native.timeoutReadySeconds == 45;
  assert builtins.attrNames controlRegistry.demo-native
  == ["autoStart" "backend" "drainStamp" "managedUnit" "readyUnit" "removalPolicy" "serviceName" "state" "timeoutReadySeconds" "uid" "unit" "user"];
  assert !(controlRegistry.demo-native ? metadataFile);
  assert !(controlRegistry.demo-native ? manifestFile);
  assert !(controlRegistry.demo-native ? privateRuntimeUnits);
  assert !(controlRegistry.demo-native ? expectedContainers);
  assert !(controlRegistry.demo-native ? workingDir);
  assert !(controlRegistry.demo-native ? verifyCommand);
  assert builtins.length invalidNativePreStopAssertions == 1;
  assert lib.hasInfix "Quadlet preStop hooks must be best-effort" (builtins.head invalidNativePreStopAssertions).message; let
    sourceInlineTextFixture = pkgs.writeText "source-inline-text.compose.yml" sourceInlineText;
  in
    pkgs.runCommand "podman-compose-module-test" {} ''
      unit_dir="$TMPDIR/quadlet-units"
      generated_dir="$TMPDIR/generated-units"
      mkdir -p "$unit_dir" "$generated_dir"
      cp -L ${native.nativeBundle}/quadlet/* "$unit_dir/"

      native_quadlet="$unit_dir/demo-native-web-container.container"
      native_image_file="$(${pkgs.jq}/bin/jq -er '.units[] | select(.kind == "remote-image") | .sourcePath | split("/") | last' ${native.nativeBundle}/report.json)"
      native_image="$unit_dir/$native_image_file"
      image_unit="''${native_image_file%.image}-image.service"

      ${pkgs.jq}/bin/jq -e '
        .kind == "quadlet-build-report"
        and .containers == [{"name": "native_web_1"}]
        and [.units[].kind] == ["network", "remote-image", "container"]
        and (has("expectedContainers") | not)
        and (has("labels") | not)
      ' ${native.nativeBundle}/report.json

      grep -F 'ContainerName=native_web_1' "$native_quadlet"

      grep -F '"opaque-secret"' ${opaqueSecret.sourcePaths."__podman-file-secrets.override.yml"}
      grep -F '/run/secrets/default-token' ${opaqueSecret.sourcePaths."__podman-file-secrets.override.yml"}
      grep -F ${lib.escapeShellArg localImageRuntimeRef} ${localImage.sourcePaths."compose.yml"}
      grep -F ${lib.escapeShellArg localImagePackageRuntimeRef} ${localImagePackageInstance.sourcePaths."compose.yml"}
      grep -F ${lib.escapeShellArg localImageStoreRuntimeRef} ${localImageStoreInstance.sourcePaths."compose.yml"}
      grep -F '.config/containers/storage.conf' ${rootlessMigrateScriptPath}
      grep -F 'mount_program' ${rootlessMigrateScriptPath}
      grep -F 'http://127.0.0.1:18080/' ${appGeneratedProbePath}
      grep -F 'probe_timeout_seconds=40' ${appGeneratedProbePath}
      grep -F 'while [ "$SECONDS" -lt "$deadline" ]' ${appGeneratedProbePath}
      grep -F 'docker.io/library/nginx:latest' ${app.sourcePaths."compose.yml"}
      grep -F 'docker.io/library/busybox:latest' ${app.sourcePaths."compose.yml"}
      cmp ${textSource.sourcePaths."compose.yml"} ${sourceInlineTextFixture}
      cmp ${fileSource.sourcePaths."compose.yml"} ${sourceFile}
      grep -F 'FROM_SIDECAR' ${extended.pullSourcePaths."sidecar.yml"}

      grep -F -- '--insecure' ${nativeGeneratedProbePath}
      grep -F -- '--resolve native.example.test:18081:127.0.0.1' ${nativeGeneratedProbePath}
      grep -F 'https://native.example.test:18081/' ${nativeGeneratedProbePath}
      grep -F '/bin/podman-quadlet-helper health wait-bundle ' ${nativeVerifyScriptPath}
      grep -F '/healthchecks.json' ${nativeVerifyScriptPath}
      grep -F "Image=$native_image_file" "$native_quadlet"
      grep -F 'Image=docker.io/library/busybox:latest' "$native_image"
      grep -F 'Policy=newer' "$native_image"
      grep -F 'Pull=never' "$native_quadlet"
      ! grep -Fq '[Quadlet]' "$native_quadlet"
      grep -F 'Volume=/srv/demo/native/data:/data:ro' "$native_quadlet"
      grep -F 'EnvironmentFile=/srv/demo/native/app.env' "$native_quadlet"
      grep -F 'Exec="printf"' "$native_quadlet"
      grep -F '$$HOME' "$native_quadlet"
      grep -F '100%%' "$native_quadlet"
      ! grep -Fq '$$$$HOME' "$native_quadlet"
      ! grep -Fq '100%%%%' "$native_quadlet"
      grep -F 'Restart=always' "$native_quadlet"
      grep -F 'PartOf=demo-native.service' "$native_quadlet"
      grep -F 'Requires=abird-host-agent-holds-ready.service' "$native_quadlet"
      grep -F 'After=abird-host-agent-holds-ready.service' "$native_quadlet"
      grep -F 'ConditionPathExists=|!${nativeHoldPath}' "$native_quadlet"
      grep -F 'ConditionPathExists=|${nativeActivationPath}' "$native_quadlet"
      grep -F 'ConditionPathExists=!${hostHoldPath}' "$native_quadlet"
      grep -F 'Requires=demo-native-stage.service' "$native_quadlet"
      grep -F 'StopWhenUnneeded=true' "$native_quadlet"
      grep -F 'Before=demo-native.service' "$native_quadlet"
      grep -F 'RequiredBy=demo-native.service' "$native_quadlet"
      grep -F 'Network=demo-native-network.network' "$native_quadlet"
      grep -F '[Install]' "$native_quadlet"

      QUADLET_UNIT_DIRS="$unit_dir" \
        ${pkgs.podman}/lib/systemd/system-generators/podman-system-generator \
        --user "$generated_dir"

      generated="$generated_dir/demo-native-web-container.service"
      test -s "$generated"
      test -s "$generated_dir/demo-native-network-network.service"
      test -s "$generated_dir/$image_unit"
      test -L "$generated_dir/demo-native.service.requires/demo-native-web-container.service"
      grep -F 'Requires=demo-native-network-network.service' "$generated"
      grep -F 'After=demo-native-network-network.service' "$generated"
      grep -F 'Restart=always' "$generated"
      grep -F 'Requires=abird-host-agent-holds-ready.service' "$generated"
      grep -F 'After=abird-host-agent-holds-ready.service' "$generated"
      grep -F 'ConditionPathExists=|!${nativeHoldPath}' "$generated"
      grep -F 'ConditionPathExists=|${nativeActivationPath}' "$generated"
      grep -F 'ConditionPathExists=!${hostHoldPath}' "$generated"
      grep -F 'TimeoutStartSec=45' "$generated"
      grep -F "Requires=$image_unit" "$generated"
      grep -F '${pkgs.podman}/bin/podman run' "$generated"
      grep -F -- '--pull never' "$generated"
      ! grep -Fq -- '--label io.abird.podman-compose.' "$generated"
      grep -F 'mv -fT -- "$tmp" "$dst"' ${../quadlet-helper.sh}
      test -e ${systemdUserGraphCheck}
      test -e ${quadletGeneratorCheck}
      touch "$out"
    ''
