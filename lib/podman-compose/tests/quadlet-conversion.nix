{pkgs}: let
  lib = pkgs.lib;
  python = pkgs.python3.withPackages (packages: [packages.pyyaml]);
  backend = import ../quadlet.nix {inherit lib pkgs;};
  composeBase = pkgs.writeText "compose.yml" ''
    services:
      db:
        image: docker.io/library/postgres:17
        devices:
          - /dev/null:/dev/test
        environment:
          POSTGRES_DB: app
        extra_hosts:
          - dbhost:10.77.0.2
        healthcheck:
          test: [CMD-SHELL, pg_isready -U postgres]
          interval: 5s
        networks:
          default:
            aliases: [database]
            ipv4_address: 10.77.0.10
        restart: unless-stopped
        ulimits:
          nofile:
            soft: 1024
            hard: 2048
        volumes:
          - ./db:/var/lib/postgresql/data
      web:
        image: ''${REGISTRY:-''${FALLBACK_REGISTRY:?missing registry}}/nginx:''${MISSING_TAG:-''${TAG:-latest}}
        depends_on:
          db:
            condition: service_healthy
        healthcheck:
          test: [CMD, sh, -c, echo healthy]
        ports: [127.0.0.1:18080:80]
    networks:
      default:
        ipam:
          config:
            - subnet: 10.77.0.0/24
  '';
  composeOverride = pkgs.writeText "compose.override.yml" ''
    services:
      db:
        devices:
          - /dev/zero:/dev/test
        environment:
          - POSTGRES_DB=app-v2
        extra_hosts:
          - dbhost=10.77.0.3
        volumes:
          - ./db-v2:/var/lib/postgresql/data
      web:
        command: [sh, -c, "echo $$HOME"]
        environment:
          FROM_OVERRIDE: "yes"
          FROM_PROJECT:
          UNRESOLVED:
        ports: [127.0.0.1:18080:80/tcp, 127.0.0.1:18081:80]
  '';
  projectEnv = pkgs.writeText "compose.env" ''
    COMPOSE_PROJECT_NAME=env-project
    REGISTRY=docker.io/library
    TAG=stable
    FROM_PROJECT=resolved
  '';
  bundleConfig = {
    systemdServiceName = "test-native";
    composeProjectName = "Test.Project";
    workingDir = "/srv/test/native";
    etcDir = "/etc/containers/systemd/users/1234";
    composeFiles = [composeBase composeOverride];
    projectEnvFile = projectEnv;
    subnet = "10.77.0.0/24";
    timeoutReadySeconds = 75;
    healthWaitProgram = "/nix/store/test-podman-quadlet-helper";
    imageRewrites = {};
    policy = {
      composeArgs = [];
      reloadMethod = "restart";
      removalPolicy = "delete";
      adopt = false;
      longRunning = true;
    };
  };
  bundle = backend.mkBundle {
    name = "test-native";
    config = bundleConfig;
  };
  localImageTag = "localhost/test/local:1";
  localImageTar = pkgs.runCommand "local-image.tar" {} ''
    mkdir archive
    printf '%s\n' \
      '[{"Config":"config.json","RepoTags":["${localImageTag}"],"Layers":[]}]' \
      > archive/manifest.json
    printf '{}\n' > archive/config.json
    tar -C archive -cf "$out" manifest.json config.json
  '';
  malformedLocalImageTar = pkgs.writeText "malformed-local-image.tar" "not an archive";
  localCompose = pkgs.writeText "local-compose.yml" ''
    services:
      app:
        image: nix-store:${localImageTar}
        environment:
          YAML11_WORD: yes
        restart: no
  '';
  localBundle = backend.mkBundle {
    name = "test-native-local";
    config =
      bundleConfig
      // {
        systemdServiceName = "test-native-local";
        composeFiles = [localCompose];
        projectEnvFile = null;
        subnet = null;
      };
  };
  invalidCompose = pkgs.writeText "invalid-compose.yml" ''
    services:
      app:
        image: docker.io/library/alpine:latest
    volumes:
      data: {}
  '';
  invalidConfig = pkgs.writeText "invalid-quadlet-input.json" (builtins.toJSON (
    bundleConfig
    // {
      composeFiles = [invalidCompose];
      projectEnvFile = null;
      subnet = null;
    }
  ));
  invalidHealthCompose = pkgs.writeText "invalid-health-compose.yml" ''
    services:
      db:
        image: docker.io/library/postgres:17
      app:
        image: docker.io/library/busybox:latest
        depends_on:
          db:
            condition: service_healthy
  '';
  invalidHealthConfig = pkgs.writeText "invalid-health-quadlet-input.json" (builtins.toJSON (
    bundleConfig
    // {
      composeFiles = [invalidHealthCompose];
      projectEnvFile = null;
      subnet = null;
    }
  ));
  invalidStoreCompose = pkgs.writeText "invalid-store-compose.yml" ''
    services:
      app:
        image: nix-store:/not/a/nix/store/archive.tar
  '';
  invalidStoreConfig = pkgs.writeText "invalid-store-quadlet-input.json" (builtins.toJSON (
    bundleConfig
    // {
      composeFiles = [invalidStoreCompose];
      projectEnvFile = null;
      subnet = null;
    }
  ));
  malformedStoreCompose = pkgs.writeText "malformed-store-compose.yml" ''
    services:
      app:
        image: nix-store:${malformedLocalImageTar}
  '';
  malformedStoreConfig = pkgs.writeText "malformed-store-quadlet-input.json" (builtins.toJSON (
    bundleConfig
    // {
      composeFiles = [malformedStoreCompose];
      projectEnvFile = null;
      subnet = null;
    }
  ));
in
  pkgs.runCommand "podman-compose-quadlet-conversion-test" {
    nativeBuildInputs = [pkgs.jq python];
  } ''
    db=${bundle}/quadlet/test-native-db-container.container
    web=${bundle}/quadlet/test-native-web-container.container
    network=${bundle}/quadlet/test-native-network.network
    report=${bundle}/report.json

    grep -F 'Subnet=10.77.0.0/24' "$network"
    grep -F 'NetworkDeleteOnStop=true' "$network"
    grep -F 'StopWhenUnneeded=true' "$network"
    grep -F 'Notify=conmon' "$db"
    if grep -F 'Notify=healthy' "$db"; then
      echo "Quadlet healthcheck unexpectedly binds readiness to the first health result" >&2
      exit 1
    fi
    grep -F 'ContainerName=env-project_db_1' "$db"
    grep -F 'ContainerName=env-project_web_1' "$web"
    grep -F 'HealthOnFailure=kill' "$db"
    if grep -F 'ExecStartPost=' "$db" "$web"; then
      echo "container health wait unexpectedly blocks systemd restart handling" >&2
      exit 1
    fi
    grep -F 'ExecStartPre="/nix/store/test-podman-quadlet-helper" "health" "wait" "env-project_db_1" "75"' "$web"
    jq -e '. == ["env-project_db_1", "env-project_web_1"]' ${bundle}/healthchecks.json
    grep -F 'TimeoutStartSec=75' "$db"
    grep -F 'TimeoutStartSec=75' "$web"
    grep -F 'HealthCmd=pg_isready -U postgres' "$db"
    grep -F "HealthCmd=sh -c 'echo healthy'" "$web"
    if grep -F 'HealthCmd=[' "$web"; then
      echo "Compose CMD healthcheck unexpectedly compiled as a literal JSON executable" >&2
      exit 1
    fi
    grep -F 'Ulimit=nofile=1024:2048' "$db"
    grep -F 'Requires=test-native-db-container.service' "$web"
    grep -F 'After=test-native-db-container.service' "$web"
    grep -F 'NetworkAlias=database' "$db"
    grep -F 'AddDevice=/dev/zero:/dev/test' "$db"
    if grep -F 'AddDevice=/dev/null:/dev/test' "$db"; then
      echo "overridden device source unexpectedly survived Compose merge" >&2
      exit 1
    fi
    grep -F 'AddHost=dbhost=10.77.0.3' "$db"
    if grep -F 'AddHost=dbhost:10.77.0.2' "$db"; then
      echo "overridden extra-host address unexpectedly survived Compose merge" >&2
      exit 1
    fi
    grep -F 'Environment="POSTGRES_DB=app-v2"' "$db"
    grep -F 'Volume=/srv/test/native/db-v2:/var/lib/postgresql/data' "$db"
    if grep -F 'Volume=/srv/test/native/db:/var/lib/postgresql/data' "$db"; then
      echo "overridden volume source unexpectedly survived Compose merge" >&2
      exit 1
    fi
    grep -F 'Restart=always' "$db"
    grep -F 'PartOf=test-native.service' "$db"
    grep -F 'StopWhenUnneeded=true' "$db"
    grep -F 'Requires=test-native-stage.service' "$db"
    grep -F 'Before=test-native.service' "$db"
    grep -F 'RequiredBy=test-native.service' "$db"
    if grep -F -- '--restart=' "$db"; then
      echo "Quadlet unexpectedly delegates restart ownership to Podman" >&2
      exit 1
    fi
    web_image_name=$(sed -n 's/^Image=\(.*\.image\)$/\1/p' "$web")
    test -n "$web_image_name"
    web_image=${bundle}/quadlet/$web_image_name
    grep -F 'Image=docker.io/library/nginx:stable' "$web_image"
    grep -F 'Policy=newer' "$web_image"
    grep -F 'StopWhenUnneeded=true' "$web_image"
    grep -F 'Exec="sh" "-c" "echo $$HOME"' "$web"
    grep -F 'Environment="FROM_OVERRIDE=yes"' "$web"
    grep -F 'Environment="FROM_PROJECT=resolved"' "$web"
    if grep -F 'Environment="UNRESOLVED=' "$web"; then
      echo "unresolved environment entry unexpectedly became an empty value" >&2
      exit 1
    fi
    grep -F 'PublishPort=127.0.0.1:18080:80/tcp' "$web"
    if grep -Fx 'PublishPort=127.0.0.1:18080:80' "$web"; then
      echo "semantically duplicated port unexpectedly survived Compose merge" >&2
      exit 1
    fi
    grep -F 'PublishPort=127.0.0.1:18081:80' "$web"
    jq -e '.kind == "quadlet-build-report"' "$report"
    jq -e '.containers | map(.name) == ["env-project_db_1", "env-project_web_1"]' "$report"
    jq -e '.units | map(.kind) | sort == ["container", "container", "network", "remote-image", "remote-image"]' "$report"
    jq -e 'has("expectedContainers") | not' "$report"
    jq -e 'has("labels") | not' "$report"

    local_report=${localBundle}/report.json
    local_container=${localBundle}/quadlet/test-native-local-app-container.container
    local_runtime=$(jq -r '.localImages[0].runtimeRef' "$local_report")
    local_image_name=$(sed -n 's/^Image=\(.*\.image\)$/\1/p' "$local_container")
    local_image=${localBundle}/quadlet/$local_image_name
    test "$local_runtime" = ${lib.escapeShellArg localImageTag}
    grep -F 'ContainerName=testproject_app_1' "$local_container"
    jq -e '.localImages | length == 1' "$local_report"
    jq -e '.declaredImages == []' "$local_report"
    grep -F "Image=docker-archive:${localImageTar}" "$local_image"
    grep -F "ImageTag=$local_runtime" "$local_image"
    grep -F 'Environment="YAML11_WORD=yes"' "$local_container"

    if python ${../quadlet-compiler.py} \
      --config ${invalidConfig} \
      --output "$TMPDIR/invalid" \
      2> "$TMPDIR/invalid.err"; then
      echo "unsupported Compose input unexpectedly compiled" >&2
      exit 1
    fi
    grep -F 'unsupported top-level keys: volumes' "$TMPDIR/invalid.err"

    if python ${../quadlet-compiler.py} \
      --config ${invalidHealthConfig} \
      --output "$TMPDIR/invalid-health" \
      2> "$TMPDIR/invalid-health.err"; then
      echo "service_healthy without a healthcheck unexpectedly compiled" >&2
      exit 1
    fi
    grep -F 'service_healthy dependency target db has no healthcheck' "$TMPDIR/invalid-health.err"

    if python ${../quadlet-compiler.py} \
      --config ${invalidStoreConfig} \
      --output "$TMPDIR/invalid-store" \
      2> "$TMPDIR/invalid-store.err"; then
      echo "invalid nix-store image unexpectedly compiled" >&2
      exit 1
    fi
    grep -F 'nix-store image must reference an existing archive file under /nix/store' "$TMPDIR/invalid-store.err"

    if python ${../quadlet-compiler.py} \
      --config ${malformedStoreConfig} \
      --output "$TMPDIR/malformed-store" \
      2> "$TMPDIR/malformed-store.err"; then
      echo "malformed nix-store image archive unexpectedly compiled" >&2
      exit 1
    fi
    grep -F 'unable to read Docker archive manifest' "$TMPDIR/malformed-store.err"
    touch "$out"
  ''
