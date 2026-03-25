{
  nixos = {...}: {};

  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    home.activation.linkEditableBin = lib.hm.dag.entryAfter ["cloneDotfiles"] ''
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
    '';
  };
}
