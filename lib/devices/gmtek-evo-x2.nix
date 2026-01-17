{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../common-hardware.nix
    ../common-graphics.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/logitech.nix
    ../hardware/tpm.nix
  ];

  # AMD Strix / GMtek bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;
}
