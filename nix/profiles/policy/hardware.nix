{
  ab,
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [ab.system.modules.hardware ab.system.hardware.desktop];
  hardware.nvidia.package =
    lib.mkIf (builtins.elem "nvidia" config.services.xserver.videoDrivers)
    (pkgs.nvidiaCustomForKernel config.boot.kernelPackages);
}
