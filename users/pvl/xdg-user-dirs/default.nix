{
  nixos = {...}: {};

  home = {...}: {
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
    };
  };
}
