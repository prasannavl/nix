{
  pkgs,
  lib,
  ...
}: let
  extension = pkgs.gnomeExtensions.dash-to-panel;
  gvariant = lib.gvariant;
  mkDict = entries: let
    names = builtins.attrNames entries;
  in
    gvariant.mkArray (map (name: gvariant.mkDictionaryEntry name entries.${name}) names);
in {
  homePackages = [extension];
  gnomeShellExtensions = [extension.extensionUuid];

  dconfSettings = {
    "org/gnome/shell/extensions/dash-to-panel" = {
      appicon-margin = 0;
      appicon-padding = 8;
      dot-style-focused = "DASHES";
      dot-style-unfocused = "DASHES";
      extension-version = 72;
      global-border-radius = 0;
      hide-overview-on-startup = true;
      hot-keys = true;
      show-favorites = true;
      animate-appicon-hover = true;
      animate-appicon-hover-animation-travel = mkDict {
        SIMPLE = 0.0;
        RIPPLE = 0.4;
        PLANK = 0.0;
      };

      animate-appicon-hover-animation-duration = mkDict {
        SIMPLE = gvariant.mkUint32 0;
        RIPPLE = gvariant.mkUint32 130;
        PLANK = gvariant.mkUint32 100;
      };
    };
  };
}
