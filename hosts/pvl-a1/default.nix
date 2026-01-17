{
  inputs,
  system,
  ...
}:
  inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {inherit inputs;};
    modules = [
      inputs.home-manager.nixosModules.home-manager
      {
        nixpkgs.overlays = import ../../overlays {inherit inputs;};
      }
      {
        imports = [
          ../../lib/nix.nix
          ../../lib/devices/asus-fa401wv.nix
          ../../lib/common-hardware.nix
          ../../lib/common-audio.nix
          ../../lib/common-graphics.nix
          ../../lib/common-network.nix
          ../../lib/common-network-wifi.nix
          ../../lib/common-printing.nix
          ../../lib/common-users.nix
          ../../lib/common-boot.nix
          ../../lib/common-kernel.nix
          ../../lib/common-locale.nix
          ../../lib/common-virtualization.nix
          ../../lib/common-programs.nix
          ../../lib/common-security.nix
          ../../lib/common-services.nix
          ../../lib/common-systemd.nix
          ../../lib/keyd.nix
          ../../lib/gnome.nix
          ../../lib/gnome-rdp.nix
          ../../lib/flatpak.nix
          ../../lib/incus.nix
          ../../lib/swap-auto-files.nix
          ./sys.nix
          ./packages.nix
          ../../users/pvl
        ];

        networking.hostName = "pvl-a1";

        # This value determines the NixOS release from which the default
        # settings for stateful data, like file locations and database versions
        # on your system were taken. It‘s perfectly fine and recommended to leave
        # this value at the release version of the first install of this system.
        # Before changing this value read the documentation for this option
        # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
        system.stateVersion = "25.11";
      }
    ];
  }
