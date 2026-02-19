{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}: let
  hostName = osConfig.networking.hostName;
in {
  home.preferXdgDirectories = true;

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };
  programs.fzf.enable = true;

  xdg = {
    enable = true;
    userDirs = lib.mkIf (lib.elem hostName ["pvl-a1"]) {
      enable = true;
      createDirectories = true;
    };
  };

  home.packages = with pkgs; [
    atool
  ];

  home.sessionPath = [
    "$HOME/bin"
  ];

  home.activation.cloneDotfiles = (lib.hm.dag.entryAfter ["writeBoundary"] ''
      hm_clone_dotfiles() {
        local repo_url dotfiles_dir should_sync
        repo_url="https://github.com/prasannavl/dotfiles.git"
        dotfiles_dir="${config.home.homeDirectory}/dotfiles"
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh"

        # Run dotfiles network sync only when switching/testing into a new HM
        # generation. On normal boot re-activation oldGenPath == newGenPath.
        should_sync=0
        if [ -z "''${oldGenPath:-}" ] || [ "$oldGenPath" != "$newGenPath" ]; then
          should_sync=1
        fi

        if [ "$should_sync" -ne 1 ]; then
          echo "Skipping dotfiles git sync (no Home Manager generation change)."
          return 0
        fi

        if [ -d "$dotfiles_dir/.git" ]; then
          $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$dotfiles_dir" fetch --all --prune
          $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$dotfiles_dir" pull --ff-only
        else
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}"
          $DRY_RUN_CMD ${pkgs.git}/bin/git clone "$repo_url" "$dotfiles_dir"
        fi
      }

      hm_clone_dotfiles
    '');

  home.activation.linkEditableBin = lib.mkIf (lib.elem hostName ["pvl-a1"]) (lib.hm.dag.entryAfter ["cloneDotfiles"] ''
      hm_link_editable_bin() {
        local dotfiles_dir bin_link
        dotfiles_dir="${config.home.homeDirectory}/dotfiles"
        bin_link="${config.home.homeDirectory}/bin"

        if [ -e "$bin_link" ] && [ ! -L "$bin_link" ]; then
          echo "Refusing to replace non-symlink path: $bin_link" >&2
          return 0
        fi

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$dotfiles_dir/bin" "$bin_link"
      }

      hm_link_editable_bin
    '');

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.11";
}
