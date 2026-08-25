{pkgs}: let
  fakeCoreutils = pkgs.buildEnv {
    name = "nginx-validator-test-coreutils";
    paths = [pkgs.coreutils];
  };
  fakePodman = pkgs.writeShellApplication {
    name = "podman";
    text = ''
      case "$1" in
        ps)
          case "''${VALIDATOR_TEST_BACKEND-quadlet}" in
            quadlet)
              printf '%s\n' "$*" | grep -Fq \
                'label=PODMAN_SYSTEMD_UNIT=test-nginx-nginx-container.service'
              ;;
            compose)
              printf '%s\n' "$*" | grep -Fq \
                'label=com.docker.compose.project.working_dir=/srv/test/nginx'
              printf '%s\n' "$*" | grep -Fq \
                'label=com.docker.compose.service=nginx'
              ;;
          esac
          case "''${VALIDATOR_TEST_CONTAINERS-one}" in
            one) printf '%s\n' test-container ;;
            many) printf '%s\n' test-container other-container ;;
          esac
          ;;
        inspect)
          printf '%s\n' test-image
          ;;
        run)
          printf '%s\n' "$@" > "$VALIDATOR_TEST_LOG"
          ;;
        *)
          printf 'unexpected podman operation: %s\n' "$1" >&2
          exit 1
          ;;
      esac
    '';
  };
  fakeSystemd = pkgs.writeShellApplication {
    name = "systemctl";
    text = ''
      if [ "''${VALIDATOR_TEST_BACKEND-quadlet}" = quadlet ]; then
        printf '%s\n' \
          test-nginx-ready.target \
          test-nginx-network-network.service \
          test-nginx-nginx-container.service
      else
        printf '%s\n' test-nginx-ready.target
      fi
    '';
  };
  fakeUtilLinux = pkgs.writeShellApplication {
    name = "runuser";
    text = ''
      while [ "$1" != -- ]; do
        shift
      done
      shift
      exec "$@"
    '';
  };
  helper = import ../services/nginx/helper.nix {
    inherit pkgs;
    runtimePackages = {
      coreutils = fakeCoreutils;
      podman = fakePodman;
      systemd = fakeSystemd;
      util-linux = fakeUtilLinux;
    };
  };
in
  pkgs.runCommand "nginx-runtime-candidate-validator-test" {} ''
    validate() {
      ${helper}/bin/nginx-helper validate-runtime-candidate \
        --runtime-user test \
        --runtime-uid 1234 \
        --service-unit test-nginx.service \
        --candidate-path /etc/nginx/conf.d/phase-route-app.conf \
        --compose-working-dir /srv/test/nginx \
        --compose-service nginx \
        "$@"
    }

    candidate="$PWD/candidate.conf"
    printf '%s\n' 'server {}' > "$candidate"
    export VALIDATOR_TEST_LOG="$PWD/podman-run.log"

    validate "$candidate"
    grep -Fx -- '--network' "$VALIDATOR_TEST_LOG"
    grep -Fx -- 'none' "$VALIDATOR_TEST_LOG"
    grep -Fx -- '--volumes-from' "$VALIDATOR_TEST_LOG"
    grep -Fx -- 'test-container' "$VALIDATOR_TEST_LOG"
    grep -Fx -- "$candidate:/etc/nginx/conf.d/phase-route-app.conf:ro" "$VALIDATOR_TEST_LOG"
    ! grep -Fq -- 'container:' "$VALIDATOR_TEST_LOG"

    VALIDATOR_TEST_BACKEND=compose \
      validate "$candidate"
    grep -Fx -- '--network' "$VALIDATOR_TEST_LOG"
    grep -Fx -- 'none' "$VALIDATOR_TEST_LOG"

    if VALIDATOR_TEST_CONTAINERS=none \
      validate "$candidate"; then
      printf '%s\n' 'validator accepted an absent runtime container' >&2
      exit 1
    fi
    if VALIDATOR_TEST_CONTAINERS=many \
      validate "$candidate"; then
      printf '%s\n' 'validator accepted ambiguous runtime containers' >&2
      exit 1
    fi

    if ${helper}/bin/nginx-helper validate-runtime-candidate \
      --runtime-user test \
      --runtime-uid 1234 \
      --service-unit test-nginx.service \
      --candidate-path /etc/nginx/conf.d/phase-route-app.conf \
      --compose-service nginx \
      "$candidate"; then
      printf '%s\n' 'validator accepted an incomplete Compose identity' >&2
      exit 1
    fi

    installed="$PWD/installed/config.conf"
    printf '%s\n' preserved > "$PWD/preserved.conf"
    ${helper}/bin/nginx-helper install-config \
      --source "$PWD/preserved.conf" \
      --target "$installed"
    grep -Fx preserved "$installed"
    ${helper}/bin/nginx-helper install-config \
      --source "$candidate" \
      --target "$installed" \
      --preserve
    grep -Fx preserved "$installed"
    ${helper}/bin/nginx-helper install-config \
      --source "$candidate" \
      --target "$installed"
    grep -Fx 'server {}' "$installed"

    touch "$out"
  ''
