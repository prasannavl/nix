{
  nixos = {...}: {};

  home = {
    config,
    lib,
    osConfig,
    pkgs,
    ...
  }: let
    homeDir = config.home.homeDirectory;
    hostName = osConfig.networking.hostName;
    onHosts = hosts: entry: lib.optional (lib.elem hostName hosts) entry;
    notHosts = hosts: entry: lib.optional (!(lib.elem hostName hosts)) entry;
  in {
    imports = [
      ./apps.nix
    ];

    gtk = {
      enable = true;
      gtk3 = {
        enable = true;

        iconTheme = {
          name = "Adwaita";
          package = pkgs.adwaita-icon-theme;
        };

        theme = {
          name = "Adwaita";
          package = pkgs.gnome-themes-extra;
        };

        cursorTheme = {
          name = "Adwaita";
          package = pkgs.adwaita-icon-theme;
        };

        bookmarks = lib.flatten [
          "file:/// /"
          "file:///${homeDir}/Documents"
          "file:///${homeDir}/Downloads"
          "file:///${homeDir}/Music"
          "file:///${homeDir}/Pictures"
          "file:///${homeDir}/Videos"
          "file:///${homeDir}/.config .config"
          "file:///${homeDir}/.local .local"
          (onHosts ["pvl-a1"] "file:///${homeDir}/src src")
          (onHosts ["pvl-a1"] "file:///${homeDir}/tmp tmp")
          (onHosts ["pvl-a1"] "file:///${homeDir}/spaces/llmug spaces:llmug")
          (notHosts ["pvl-x2"] "sftp://pvl-x2/home/pvl ssh:pvl-x2/pvl")
        ];
      };
    };
  };
}
