{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../hardware/mesa.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/logitech.nix
    ../hardware/tpm.nix
  ];

  # AMD Strix / GMtek bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;
}
