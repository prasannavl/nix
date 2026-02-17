{
  nixos = {...}: {};

  home = {pkgs, ...}: {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      extraLuaConfig = builtins.readFile ./init.lua;
      plugins = [
        # We basically use the LazyVim distro instead
        # of using the lazy plugin manager directly.
        # We let it download and manage. 
        # Note: mason and friends, will not work without nixld.
        # pkgs.vimPlugins.lazy-nvim
      ];
    };

    xdg.configFile."nvim/lua" = {
      source = ./lua;
      recursive = true;
    };

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
