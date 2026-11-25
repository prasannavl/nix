{pkgs}: let
  inherit (pkgs.stdenv.hostPlatform.go) GOOS GOARCH;
  nativePlatform = "${GOOS}/${GOARCH}";
  ownerPath = "${pkgs.podman}/bin:/run/wrappers/bin:${pkgs.lib.makeBinPath [pkgs.coreutils pkgs.dnsutils pkgs.skopeo pkgs.util-linux]}:/run/current-system/sw/bin";
  python = pkgs.python3.withPackages (ps: [(ps.toPythonModule pkgs.podman-compose)]);
  script = ./compose-image-plan.py;
  project = pkgs.writeShellScriptBin "podman-compose-project" ''
    set -eu
    metadata=$1 mode=$2
    shift 2
    legacy=""
    if [[ $mode == legacy-stop ]]; then
      mode=$1; shift
      case "$mode" in inventory|engine|provider) ;; *) exit 2 ;; esac
      legacy=legacy-stop-
    fi
    case "$mode" in
      provider) set -- ${python}/bin/python ${script} "$metadata" "''${legacy}provider" ${pkgs.podman-compose}/bin/podman-compose "$@" ;;
      inventory) set -- ${python}/bin/python ${script} "$metadata" "''${legacy}inventory" ;;
      images) set -- ${python}/bin/python ${script} "$metadata" "$@" ;;
      engine) set -- ${pkgs.podman}/bin/podman "$@" ;;
      *) echo 'expected provider, inventory, images or engine' >&2; exit 2 ;;
    esac
    if [[ -n $legacy ]]; then
      # Old ExecStop inherits the old unit environment, including registry and
      # interpolation settings. Keep systemd notifications inside the helper.
      unset NOTIFY_SOCKET WATCHDOG_PID WATCHDOG_USEC
      export PATH=${ownerPath}
      exec "$@"
    fi
    mapfile -d "" -t variables < <(${pkgs.jq}/bin/jq --raw-output0 \
      '(.projectEnvironment // {}) | to_entries[] | "\(.key)=\(.value)"' "$metadata")
    wait "$!"
    account=$(${pkgs.getent}/bin/getent passwd "$UID")
    IFS=: read -r owner _ _ _ _ home _ <<< "$account"
    exec ${pkgs.coreutils}/bin/env -i -- "''${variables[@]}" \
      HOME="$home" USER="$owner" LOGNAME="$owner" XDG_RUNTIME_DIR="/run/user/$UID" \
      NIX_PODMAN_NATIVE_PLATFORM=${nativePlatform} PATH=${ownerPath} "$@"
  '';
in {
  inherit ownerPath project;
  verifyNative = pkgs.writeShellScript "podman-verify-native-image" ''
    unset NOTIFY_SOCKET WATCHDOG_PID WATCHDOG_USEC
    export PATH=${ownerPath} NIX_PODMAN_NATIVE_PLATFORM=${nativePlatform}
    exec ${pkgs.python3}/bin/python ${script} --verify-native "$@"
  '';
  nativeImages = pkgs.writeShellScriptBin "podman-owner-images" ''
    set -eu
    # Share Compose's per-owner write lock, not its startup/preflight graph.
    locks="$XDG_RUNTIME_DIR/podman-compose"
    ${pkgs.coreutils}/bin/install -d -m0700 "$locks"
    exec 6>"$locks/rootless-lifecycle-v1.lock"
    ${pkgs.util-linux}/bin/flock -x -w 1 -E 75 6
    export NIX_PODMAN_NATIVE_PLATFORM=${nativePlatform}
    exec ${pkgs.python3}/bin/python ${script} --ensure-native "$@"
  '';
}
