{
  nixos = {...}: {};

  home = {config, lib, pkgs, ...}: {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      # We don't do config here, we link the whole nvim config from our dotfiles.
      # plugins = [
        # We basically use the LazyVim distro instead
        # of using the lazy plugin manager directly.
        # We let it download and manage. 
        # Note: mason and friends, will not work without nixld.
        # pkgs.vimPlugins.lazy-nvim
      # ];
    };

    home.activation.linkEditableNvim = lib.hm.dag.entryAfter ["cloneDotfiles"] ''
      dotfiles_nvim="${config.home.homeDirectory}/dotfiles/nvim/.config/nvim"
      nvim_link="${config.home.homeDirectory}/.config/nvim"

      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}/.config"

      if [ -e "$nvim_link" ] && [ ! -L "$nvim_link" ]; then
        echo "Refusing to replace non-symlink path: $nvim_link" >&2
        exit 1
      fi

      $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$dotfiles_nvim" "$nvim_link"
    '';

    home.packages = with pkgs; [
      git
      ripgrep
      fd
      gcc
      tree-sitter
      nix-ld
    ];
  };
}
