{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../hardware/amdgpu-strix.nix
    ../hardware/logitech.nix
    ../hardware/mt7921e.nix
    ../hardware/nvidia.nix
    ../hardware/openrgb.nix
    ../hardware/tpm.nix
  ];

  # AMD Strix / ASUS bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;

  # Adds the missing asus functionality to Linux.
  # https://asus-linux.org/manual/asusctl-manual/
  # Note: It generates a lot of spam logs currently
  # So we just have it disabled for now, since it's
  # doesn't bring any key features, just nice to have.
  # services.asusd = {
  #   enable = true;
  #   # This device doesn't have LEDs that this enables.
  #   # enableUserService = true;
  # };

  # Enable gfx mux control
  services.supergfxd.enable = true;

  # Key remaps
  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = ["0001:0001:3cf016cc"];
        settings = {
          main = {
            # Right ctrl Key mapping
            "leftmeta+leftshift+f23" = "layer(control)";
          };
        };
      };
    };
  };

  # Sysrq key maps due to the lack of print scr
  services.udev.extraHwdb = ''
    # AT Translated Set 2 keyboard
    evdev:name:AT Translated Set 2 keyboard:*
     KEYBOARD_KEY_dd=sysrq

    # Asus WMI hotkeys
    evdev:name:Asus WMI hotkeys:*
     KEYBOARD_KEY_38=sysrq
  '';
}
