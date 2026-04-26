{pkgs}: let
  # Common idle timeout reference:
  # 5 min  = 300
  # 7 min  = 420
  # 8 min  = 480
  # 10 min = 600
  # 12 min = 720
  # 15 min = 900
  # 20 min = 1200
  # 30 min = 1800
  defaultTimeouts = {
    battery = {
      lock = 600;
      screenPowerOff = 601;
      suspend = 900;
    };
    ac = {
      lock = 900;
      screenPowerOff = 901;
    };
  };
  lockScript = pkgs.writeShellScript "wm-lock" ''
    exec ${pkgs.swaylock}/bin/swaylock -f -c 000000 --indicator-idle-visible
  '';
  isOnAcScript = pkgs.writeShellScript "wm-on-ac" ''
    set -eu

    found_battery=0

    for supply in /sys/class/power_supply/*; do
      [[ -d "$supply" ]] || continue
      [[ -r "$supply/type" ]] || continue

      type="$(cat "$supply/type")"

      if [[ "$type" == "Battery" ]]; then
        found_battery=1
        continue
      fi

      if [[ "$type" == "Mains" && -r "$supply/online" && "$(cat "$supply/online")" == "1" ]]; then
        exit 0
      fi
    done

    if [[ "$found_battery" == "1" ]]; then
      exit 1
    fi

    # Systems without a battery should follow the AC policy.
    exit 0
  '';
  mkConditionalScript = name: onAc: actionScript:
    pkgs.writeShellScript name ''
      set -eu

      if ${isOnAcScript}; then
        ${
        if onAc
        then "exec"
        else "exit"
      } ${
        if onAc
        then actionScript
        else "0"
      }
      fi

      ${
        if onAc
        then "exit 0"
        else "exec ${actionScript}"
      }
    '';
  suspendScript = pkgs.writeShellScript "wm-suspend" ''
    exec ${pkgs.systemd}/bin/systemctl suspend
  '';
in {
  inherit defaultTimeouts;

  mkIdleService = {
    name,
    description,
    readyTarget,
    sessionUnit,
    powerOffCommand,
    powerOnCommand,
    timeouts ? defaultTimeouts,
  }: let
    powerOffScript = pkgs.writeShellScript "${name}-power-off-monitors" ''
      exec ${powerOffCommand}
    '';
    powerOnScript = pkgs.writeShellScript "${name}-power-on-monitors" ''
      exec ${powerOnCommand}
    '';
    idleCommand = pkgs.writeShellScriptBin name ''
      exec ${pkgs.swayidle}/bin/swayidle -w \
        timeout ${toString timeouts.battery.lock} '${mkConditionalScript "${name}-battery-lock" false lockScript}' \
        timeout ${toString timeouts.battery.screenPowerOff} '${mkConditionalScript "${name}-battery-power-off" false powerOffScript}' \
        timeout ${toString timeouts.ac.lock} '${mkConditionalScript "${name}-ac-lock" true lockScript}' \
        timeout ${toString timeouts.ac.screenPowerOff} '${mkConditionalScript "${name}-ac-power-off" true powerOffScript}' \
        timeout ${toString timeouts.battery.suspend} '${mkConditionalScript "${name}-battery-suspend" false suspendScript}' \
        resume '${powerOnScript}' \
        before-sleep '${lockScript}'
    '';
  in {
    Unit = {
      Description = description;
      PartOf = [
        readyTarget
        sessionUnit
      ];
      After = [readyTarget];
      Requisite = [readyTarget];
    };
    Service = {
      ExecStart = pkgs.lib.getExe idleCommand;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = [readyTarget];
  };
}
