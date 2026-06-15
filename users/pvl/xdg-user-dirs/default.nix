{
  nixos = {...}: {};

  home = {
    lib,
    options,
    ...
  }: {
    xdg.configFile."user-dirs.dirs".force = true;
    xdg.userDirs =
      {
        enable = true;
        createDirectories = true;
      }
      // lib.optionalAttrs (options.xdg.userDirs ? setSessionVariables) {
        setSessionVariables = true;
      };
  };
}
