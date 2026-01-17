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
          ../../lib/flatpak.nix
          ../../lib/gnome.nix
          ../../lib/gnome-rdp.nix
          ../../lib/common-locale.nix
          ../../lib/common-virtualization.nix
          ../../lib/common-network-wifi.nix
          ../../lib/common-users.nix
          ../../lib/common-boot.nix
          ../../lib/common-kernel.nix
          ../../users/pvl
          ../../hosts/pvl-a1/packages.nix
          ../../lib/common-programs.nix
          ../../lib/common-security.nix
          ../../lib/common-services.nix
          ../../lib/incus.nix
          ../../lib/swap-auto-files.nix
          ../../lib/common-systemd.nix
          ../../hosts/pvl-a1/users.nix
        ];

        networking.hostName = "pvl-x2";
      }
    ];
  }
