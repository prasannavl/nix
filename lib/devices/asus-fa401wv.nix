{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../hardware/mesa.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/nvidia.nix
    ../hardware/logitech.nix
    ../hardware/mt7921e.nix
    ../hardware/openrgb.nix
    ../hardware/tpm.nix
    ../keyd.nix
  ];

  # AMD Strix / ASUS bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;

  hardware.nvidia = {
    prime = {
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
  };

  boot.extraModprobeConfig = ''
    # Attempt amdgpu binds before nvidia. This doesn't happen if the
    # PCI device comes earlier, but we try anyway.
    softdep nvidia pre: amdgpu
    softdep nvidia_drm pre: amdgpu
    softdep nouveau pre: amdgpu
  '';

  # Additional stable paths
  services.udev.extraRules = ''
    KERNEL=="card*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/zcard-amd"
    KERNEL=="card*", ATTRS{vendor}=="0x10de", SYMLINK+="dri/zcard-nvidia"
    KERNEL=="renderD*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/zrender-amd"
    KERNEL=="renderD*", ATTRS{vendor}=="0x10de", SYMLINK+="dri/zrender-nvidia"
  '';

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
    keyboards = {
      default = {
        ids = ["0001:0001:3cf016cc"];
        settings = {
          main = {
            # Right ctrl key mapping (from co-pilot key)
            "leftmeta+leftshift+f23" = "layer(control)";
          };
        };
      };
    };
  };

  services.udev.extraHwdb = ''
    # Sysrq key maps (Since it lacks print scr)
    # ===
    # dev: AT Translated Set 2 keyboard
    # key: Fn + Left Ctrl
    evdev:name:AT Translated Set 2 keyboard:*
     KEYBOARD_KEY_dd=sysrq

    # dev: Asus WMI hotkeys
    # key: Armory crate
    # notes: This isn't picked up kernel as it only
    # listens to AT device.
    evdev:name:Asus WMI hotkeys:*
     KEYBOARD_KEY_38=sysrq
  '';
}
