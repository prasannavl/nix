let
  monospaceNerdFont = "JetBrainsMono Nerd Font Mono";
in {
  nixos = {
    lib,
    pkgs,
    ...
  }: {
    fonts = {
      packages = [
        pkgs.nerd-fonts.jetbrains-mono
        pkgs.nerd-fonts.symbols-only
      ];

      fontconfig.defaultFonts.monospace = lib.mkAfter [
        monospaceNerdFont
        "Symbols Nerd Font Mono"
      ];
    };
  };

  home = {...}: {
    dconf.settings."org/gnome/desktop/interface" = {
      monospace-font-name = "${monospaceNerdFont} 11";
    };
  };
}
