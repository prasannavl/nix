{
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      kanshi
    ];
  };

  home = {
    lib,
    osConfig,
    pkgs,
    ...
  }: let
    inherit (osConfig.networking) hostName;
    outputs = import ../wm/outputs.nix;
    wmServices = import ../wm/services.nix {};
    configDefaults = import ./config-defaults.nix {
      lib = lib;
      outputs = outputs;
    };
    commonProfiles = "";
    profilesByHost = import ./profiles.nix {outputs = outputs;};
    hostProfiles = lib.attrByPath [hostName] "" profilesByHost;
    configText = lib.concatStringsSep "\n\n" (
      [configDefaults]
      ++ lib.optional (commonProfiles != "") commonProfiles
      ++ lib.optional (hostProfiles != "") hostProfiles
    );
  in {
    xdg.configFile."kanshi/config".text = configText;

    systemd.user.services.kanshi =
      wmServices.mkWmPostService
      "Dynamic Output Configuration"
      "${pkgs.kanshi}/bin/kanshi";
  };
}
