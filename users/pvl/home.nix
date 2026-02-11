{
  config,
  pkgs,
  lib,
  osConfig ? {},
  ...
}: let
  userdata = (import ../userdata.nix).pvl;
  hostName = osConfig.networking.hostName or "";
  hostModules = {
    pvl-x2 = [];
    pvl-a1 = [];
  };
  selectedModulePaths = lib.attrByPath [hostName] [] hostModules;
in {
  _module.args = {inherit userdata;};

  imports = selectedModulePaths;

  home.preferXdgDirectories = true;

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };
  programs.fzf.enable = true;

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
    };
  };
  

  home.packages = with pkgs; [
    atool
  ];

  home.file = {
    # ".config/containers/storage.conf".text = ''
    #   [storage]
    #   driver = "overlay"
    #
    #   [storage.options]
    #   mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
    # '';
    # ".config/chrome-flags.conf".text = ''
    #   --disable-smooth-scrolling
    # '';
  };

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.11";
}
