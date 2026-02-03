{
  nixos = {...}: {
    programs.neovim.enable = true;
  };

  home = {...}: {
    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
    };
  };
}
