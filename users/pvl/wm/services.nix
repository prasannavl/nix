{...}: let
  sessionUnits = {
    niri = "niri.service";
    sway = "sway-session.target";
  };
  sessionTargets = builtins.attrValues sessionUnits;
  readyTargets = {
    niri = "wm-session-ready-niri";
    sway = "wm-session-ready-sway";
  };
  readyTargetUnits = builtins.mapAttrs (_: unit: "${unit}.target") readyTargets;
  allReadyTargets = builtins.attrValues readyTargetUnits;
  portalUnits = [
    "xdg-document-portal.service"
    "xdg-desktop-portal.service"
    "xdg-desktop-portal-gtk.service"
    "xdg-desktop-portal-gnome.service"
    "xdg-desktop-portal-wlr.service"
  ];
  portalBackendUnits = [
    "xdg-desktop-portal-gtk.service"
  ];
  mkWmScripts = pkgs: let
    renderShellArray = units:
      pkgs.lib.concatMapStringsSep "\n" (unit: "  ${unit}") units;
    portalUnitArray = renderShellArray portalUnits;
    portalBackendUnitArray = renderShellArray portalBackendUnits;
    portalCleanup = pkgs.writeShellApplication {
      name = "portal-cleanup";
      runtimeInputs = [
        pkgs.systemd
      ];
      # Stop only. Do NOT reset-failed here: if a backend failed during
      # compositor teardown (broken-pipe → dbus reactivation → "cannot open
      # display"), clearing the failed state races with systemd's failure
      # notification to dbus-broker. The lost notification leaves a pending
      # dbus activation slot that only resolves after the 120s
      # service_start_timeout, hanging portal-dependent apps in the next
      # session. Leaving the failed state intact lets dbus see the failure
      # and resolve the slot promptly. Reset happens in preparePortals
      # right before a fresh start.
      text = ''
        set -Eeuo pipefail

        units=(
        ${portalUnitArray}
        )

        for unit in "''${units[@]}"; do
          systemctl --user stop "$unit" 2>/dev/null || true
        done
      '';
    };
  in {
    portalCleanup = portalCleanup;
    preparePortals = pkgs.writeShellApplication {
      name = "wm-session-portals-prepare";
      runtimeInputs = [
        pkgs.systemd
      ];
      text = ''
        set -Eeuo pipefail

        ${pkgs.lib.getExe portalCleanup}

        portal_backends=(
        ${portalBackendUnitArray}
        )

        for unit in "''${portal_backends[@]}"; do
          systemctl --user reset-failed "$unit" 2>/dev/null || true
        done

        systemctl --user start "''${portal_backends[@]}"
      '';
    };
  };
  mkWmPostService = description: execStart: {
    Unit = {
      Description = description;
      PartOf = allReadyTargets ++ sessionTargets;
      After = allReadyTargets;
    };
    Service = {
      ExecStart = execStart;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = allReadyTargets;
  };
in {
  inherit sessionUnits sessionTargets readyTargets readyTargetUnits allReadyTargets portalUnits portalBackendUnits mkWmScripts mkWmPostService;
}
