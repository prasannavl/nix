{
  nixos = _: {};

  home = _: {
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
    };
  };
}
