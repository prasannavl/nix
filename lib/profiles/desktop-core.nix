{...}: {
  imports = [
    ./core.nix
    ../audio.nix
    ../desktop-base.nix
    ../wm.nix
    ../gpg.nix
    ../mdns.nix
  ];

  programs.seahorse.enable = true;
  programs.firefox.enable = true;
}
