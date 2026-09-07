{
  nixos = {...}: {};

  home = {
    config,
    pkgs,
    ...
  }: let
    syncDotfiles = pkgs.writeShellScript "sync-dotfiles" ''
      set -Eeuo pipefail

      init_vars() {
        home_dir="${config.home.homeDirectory}"
        dotfiles_dir="$home_dir/dotfiles"
        bin_dir="$home_dir/bin"
        repo_host="github.com"
        repo_url="https://$repo_host/prasannavl/dotfiles.git"
        network_attempts=5
        network_retry_seconds=2
        git_timeout=60s
        getent="${pkgs.getent}/bin/getent"
        git="${pkgs.git}/bin/git"
        ln="${pkgs.coreutils}/bin/ln"
        mkdir="${pkgs.coreutils}/bin/mkdir"
        sleep="${pkgs.coreutils}/bin/sleep"
        timeout="${pkgs.coreutils}/bin/timeout"
      }

      wait_for_network() {
        local attempts="$network_attempts"
        while ! "$getent" hosts "$repo_host" >/dev/null; do
          attempts=$((attempts - 1))
          [ "$attempts" -gt 0 ] || return 1
          "$sleep" "$network_retry_seconds"
        done
      }

      main() {
        init_vars

        if [ -e "$dotfiles_dir" ] && [ ! -d "$dotfiles_dir/.git" ]; then
          echo "Refusing to replace non-Git path: $dotfiles_dir" >&2
          return 1
        fi
        if [ -e "$bin_dir" ] && [ ! -L "$bin_dir" ]; then
          echo "Refusing to replace non-symlink path: $bin_dir" >&2
          return 1
        fi

        "$mkdir" -p "$home_dir"
        if ! wait_for_network; then
          echo "Dotfiles network unavailable; the timer will retry later" >&2
        elif [ -d "$dotfiles_dir/.git" ]; then
          if "$timeout" "$git_timeout" "$git" -C "$dotfiles_dir" fetch --all --prune; then
            "$git" -C "$dotfiles_dir" merge --ff-only '@{upstream}'
          else
            echo "Dotfiles fetch unavailable; keeping the existing checkout" >&2
          fi
        elif ! "$timeout" "$git_timeout" "$git" clone "$repo_url" "$dotfiles_dir"; then
          echo "Dotfiles clone unavailable; the timer will retry later" >&2
        fi

        if [ -d "$dotfiles_dir/.git" ]; then
          "$ln" -sfn "$dotfiles_dir/bin" "$bin_dir"
        fi
      }

      main "$@"
    '';
  in {
    systemd.user.services.dotfiles-sync = {
      Unit = {
        Description = "Sync editable dotfiles checkout";
        Documentation = "https://github.com/prasannavl/dotfiles";
        Wants = ["network-online.target"];
        After = ["network-online.target"];
        X-SwitchMethod = "keep-old";
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
