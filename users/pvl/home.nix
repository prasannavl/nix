{
  userdata,
  selectedModules,
}: {
  pkgs,
  inputs,
  ...
}: {
  home-manager.users.pvl.imports =
    [
      inputs.noctalia.homeModules.default
      {_module.args = {inherit userdata;};}
      {
        xdg.enable = true;
        home.preferXdgDirectories = true;
        home.packages = with pkgs; [atool];
        home.sessionPath = ["$HOME/bin"];

        # The state version is required and should stay at the version you
        # originally installed.
        home.stateVersion = "25.11";
      }
    ]
    ++ map (x: x.home) selectedModules;
}
