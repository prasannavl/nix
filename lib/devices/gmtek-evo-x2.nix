{...}: {
  imports = [
    ../hardware/mesa.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/logitech.nix
    ../hardware/tpm.nix
  ];

  # AMD Strix / GMtek bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;

  services.udev.extraRules = ''
    KERNEL=="card*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/zcard-amd"
    KERNEL=="renderD*", ATTRS{vendor}=="0x1002", SYMLINK+="dri/zrender-amd"
  '';
}
