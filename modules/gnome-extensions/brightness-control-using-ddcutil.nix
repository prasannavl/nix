{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.brightness-control-using-ddcutil;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];

  dconfSettings = {
    "org/gnome/shell/extensions/display-brightness-ddcutil" = {
      button-location = 1;
      ddcutil-binary-path = "${pkgs.ddcutil}/bin/ddcutil";
    };
  };
}
