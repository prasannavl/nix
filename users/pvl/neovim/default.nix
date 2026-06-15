{
  nixos = {...}: {};

  home = {pkgs, ...}: {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      withPython3 = true;
      withRuby = true;
      plugins = [
        # Note: mason and friends, will not work without nixld.
        pkgs.vimPlugins.lazy-nvim
      ];
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
