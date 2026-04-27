{
  pkgs,
  config,
}: let
  screenshotDir = "${config.home.homeDirectory}/Pictures/Screenshots";
  grimshotBin = "${pkgs.sway-contrib.grimshot}/bin/grimshot";
  wrapped = pkgs.writeShellApplication {
    name = "grimshot-debounced";
    runtimeInputs = [pkgs.coreutils pkgs.util-linux];
    text = ''
      export XDG_SCREENSHOTS_DIR="${screenshotDir}"
      mkdir -p "$XDG_SCREENSHOTS_DIR"
      runtime="''${XDG_RUNTIME_DIR:-/tmp}"
      lock="$runtime/grimshot.lock"
      mark="$runtime/grimshot.mark"
      now_ms=$(date +%s%3N)
      if [ -f "$mark" ] && [ "$((now_ms - $(date -r "$mark" +%s%3N)))" -lt 250 ]; then
        exit 0
      fi
      exec 9>"$lock"
      if ! flock -n 9; then
        exit 0
      fi
      # shellcheck disable=SC2329
      cleanup() {
        flock -u 9 || true
        rm -f "$lock"
      }
      trap cleanup EXIT
      rc=0
      ${grimshotBin} "$@" || rc=$?
      touch "$mark"
      exit "$rc"
    '';
  };
in {
  inherit screenshotDir grimshotBin;
  package = wrapped;
  bin = "${wrapped}/bin/grimshot-debounced";
}
