{
  nixos = {...}: {};

  home = {...}: {
    xdg.configFile."user-dirs.dirs".force = true;
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
    };
  };
}
