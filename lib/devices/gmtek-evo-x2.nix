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
    KERNEL=="card*", KERNELS=="0000:c6:00.0", SYMLINK+="dri/zcard-amd", SYMLINK+="dri/zcard-default"
    KERNEL=="renderD*", KERNELS=="0000:c6:00.0", SYMLINK+="dri/zrender-amd", SYMLINK+="dri/zrender-default"
  '';
}
