{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./lib/common.nix
    ./lib/common-graphics.nix
    ./lib/amdgpu-strix.nix
    ./lib/logitech.nix
  ];

  # AMD Strix / GMtek bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;
}
