{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./boot.nix
    ./flatpak.nix
    ./gnome.nix
    ./hardware.nix
    ./hardwarez.nix
    ./locale.nix
    ./misc.nix
    ./network.nix
    ./packages.nix
    ./programs.nix
    ./security.nix
    ./services.nix
    ./swap.nix
    ./systemd.nix
    ./users.nix
    ./xdg.nix
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://numtide.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;

  # Handy to have this linked for debugging
  environment.pathsToLink = ["/libexec"];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11";
}
