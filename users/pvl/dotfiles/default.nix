{
  nixos = {...}: {};

  home = {
    config,
    pkgs,
    ...
  }: let
    syncDotfiles = pkgs.writeShellScript "sync-dotfiles" ''
      set -eu

      vars() {
        home_dir="${config.home.homeDirectory}"
        dotfiles_dir="$home_dir/dotfiles"
        bin_dir="$home_dir/bin"
        getent="${pkgs.getent}/bin/getent"
        git="${pkgs.git}/bin/git"
        ln="${pkgs.coreutils}/bin/ln"
        mkdir="${pkgs.coreutils}/bin/mkdir"
        sleep="${pkgs.coreutils}/bin/sleep"
      }

      wait_for_network() {
        local attempts host
        attempts=5
        host="github.com"

        while ! "$getent" hosts "$host" >/dev/null; do
          attempts=$((attempts - 1))
          if [ "$attempts" -le 0 ]; then
            echo "Timed out waiting for DNS resolution of $host" >&2
            return 1
          fi

          "$sleep" 2
        done
      }

      sync_dotfiles() {
        local repo_url
        repo_url="https://github.com/prasannavl/dotfiles.git"
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh"

        if [ -d "$dotfiles_dir/.git" ]; then
          "$git" -C "$dotfiles_dir" fetch --all --prune
          "$git" -C "$dotfiles_dir" pull --ff-only
        else
          "$mkdir" -p "$home_dir"
          "$git" clone "$repo_url" "$dotfiles_dir"
        fi
      }

      link_editable_bin() {
        if [ -e "$bin_dir" ] && [ ! -L "$bin_dir" ]; then
          echo "Refusing to replace non-symlink path: $bin_dir" >&2
          return 1
        fi

        "$ln" -sfn "$dotfiles_dir/bin" "$bin_dir"
      }

      vars
      wait_for_network
      sync_dotfiles
      link_editable_bin
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
        OnStartupSec = "30s";
        OnCalendar = "daily";
        AccuracySec = "5m";
        Persistent = true;
      };

      Install.WantedBy = ["timers.target"];
    };
  };
}
