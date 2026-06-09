{
  userdata,
  selectedModules,
}: {inputs, ...}: {
  home-manager.users.pvl.imports =
    [
      inputs.noctalia.homeModules.default
      {_module.args = {inherit userdata;};}
      ({pkgs, ...}: {
        xdg.enable = true;
        xdg.configFile."user-dirs.dirs".force = true;

        home = {
          preferXdgDirectories = true;
          packages = with pkgs; [atool];
          sessionPath = [
            "$HOME/bin"
          ];

          # The state version is required and should stay at the version you
          # originally installed.
          stateVersion = "25.11";
        };
      })
    ]
    ++ map (x: x.home) selectedModules;
}
