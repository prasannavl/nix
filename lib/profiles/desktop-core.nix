{...}: {
  imports = [
    ./core.nix
    ../audio.nix
    ../desktop-base.nix
    ../sway.nix
    ../gpg.nix
    ../mdns.nix
  ];

  programs.seahorse.enable = true;
  programs.firefox.enable = true;
}
