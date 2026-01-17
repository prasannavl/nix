{
  config,
  pkgs,
  ...
}: {
  services.flatpak.enable = true;

  systemd.services.flatpak-add-flathub = {
    description = "Ensure Flathub Flatpak remote exists (system-wide)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];

    path = [pkgs.flatpak];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      # If it's already there, let's not attempt to try, since if we're early
      # before network, it will fail.
      if flatpak remotes --system --columns=name | grep -qx 'flathub'; then
        exit 0
      fi

      flatpak remote-add --system --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo;
    '';
  };
}
