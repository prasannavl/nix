{...}: {
  imports = [
    ./desktop-core.nix
    # ../seatd.nix
  ];

  programs.sway.enable = true;
}
