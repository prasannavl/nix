{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.bluetooth-quick-connect;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];

  dconfSettings = {
    "org/gnome/shell/extensions/bluetooth-quick-connect" = {
      keep-menu-on-toggle = true;
      refresh-button-on = true;
      show-battery-value-on = true;
    };
  };
}
