{...}: {
  imports = [
    ./core.nix
    ../audio.nix
    ../x11.nix
    ../gpg.nix
    ../mdns.nix
  ];

  programs.seahorse.enable = true;
  programs.firefox.enable = true;
}
