{
  nixos = {...}: {};

  home = {config, ...}: let
    homeDir = config.home.homeDirectory;
  in {
    gtk = {
      enable = true;
      gtk3 = {
        enable = true;
        bookmarks = [
          "file:/// /"
          "file:///${homeDir}/Documents"
          "file:///${homeDir}/Downloads"
          "file:///${homeDir}/Music"
          "file:///${homeDir}/Pictures"
          "file:///${homeDir}/Videos"
          "file:///${homeDir}/.config .config"
          "file:///${homeDir}/.local .local"
          "file:///${homeDir}/src src"
          "file:///${homeDir}/tmp tmp"
          "file:///${homeDir}/spaces/llmug spaces:llmug"
          "sftp://pvl-x2/home/pvl ssh:pvl-x2/pvl"
        ];
      };
    };
  };
}
