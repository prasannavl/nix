{
  nixos = {...}: {};

  home = {
    config,
    pkgs,
    ...
  }: let
    syncDotfiles = pkgs.writeShellScript "sync-dotfiles" ''
      set -eu

      sync_dotfiles() {
        local repo_url dotfiles_dir
        repo_url="https://github.com/prasannavl/dotfiles.git"
        dotfiles_dir="${config.home.homeDirectory}/dotfiles"
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh"

        if [ -d "$dotfiles_dir/.git" ]; then
          ${pkgs.git}/bin/git -C "$dotfiles_dir" fetch --all --prune
          ${pkgs.git}/bin/git -C "$dotfiles_dir" pull --ff-only
        else
          ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}"
          ${pkgs.git}/bin/git clone "$repo_url" "$dotfiles_dir"
        fi
      }

      sync_dotfiles
    '';
  in {
    systemd.user.services.dotfiles-sync = {
      Unit = {
        Description = "Sync editable dotfiles checkout";
        Documentation = "https://github.com/prasannavl/dotfiles";
        Wants = ["network-online.target"];
        After = ["network-online.target"];
      };

      Service = {
        Type = "oneshot";
        ExecStart = syncDotfiles;
      };
    };

    systemd.user.timers.dotfiles-sync = {
      Unit.Description = "Periodically sync editable dotfiles checkout";

      Timer = {
        OnStartupSec = "0";
        OnUnitActiveSec = "1d";
        AccuracySec = "5m";
        Persistent = true;
      };

      Install.WantedBy = ["timers.target"];
    };
  };
}
