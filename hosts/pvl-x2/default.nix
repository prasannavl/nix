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
          ../../lib/devices/gmtek-evo-x2.nix
          ../../lib/audio.nix
          ../../lib/boot.nix
          ../../lib/flatpak.nix
          ../../lib/gdm-rdp.nix
          ../../lib/gdm.nix
          ../../lib/gnome.nix
          ../../lib/gpg.nix
          ../../lib/graphics.nix
          ../../lib/hardware.nix
          ../../lib/incus.nix
          ../../lib/kernel.nix
          ../../lib/printing.nix
          ../../lib/incus.nix
          ../../lib/kernel.nix
          ../../lib/locale.nix
          ../../lib/mdns.nix
          ../../lib/neovim.nix
          ../../lib/network-wifi.nix
          ../../lib/network.nix
          ../../lib/nix-ld.nix
          ../../lib/printing.nix
          ../../lib/security.nix
          ../../lib/sudo.nix
          ../../lib/swap-auto.nix
          ../../lib/systemd.nix
          ../../lib/sysctl-inotify.nix
          ../../lib/sysctl-kernel-coredump.nix
          ../../lib/sysctl-kernel-panic.nix
          ../../lib/sysctl-kernel-sysrq.nix
          ../../lib/sysctl-vm.nix
          ../../lib/users.nix
          ../../lib/virtualization.nix
          ../../lib/x11.nix
          ../../lib/profiles/all.nix
          ./sys.nix
          ./packages.nix
          ../../users/pvl
        ];

        networking.hostName = "pvl-x2";

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
