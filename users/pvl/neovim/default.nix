{
  nixos = {...}: {
    programs.neovim.enable = true;
  };

  home = {...}: {
    programs.neovim = {
      enable = false;
      viAlias = true;
      vimAlias = true;
    };
  };
}
