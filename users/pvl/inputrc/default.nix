{
  config,
  lib,
  ...
}: let
  src = ./.inputrc;
in {
  nixos = {};

  home = let
    useXdg = config.home.preferXdgDirectories;
  in
    lib.mkMerge [
      (lib.mkIf useXdg {
        xdg.configFile."inputrc".source = src;
      })
      (lib.mkIf (!useXdg) {
        home.file.".inputrc".source = src;
      })
    ];
}
