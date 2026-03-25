{
  nixos = {...}: {};

  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    home.activation.cloneDotfiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
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
    '';
  };
}
