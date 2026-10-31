{pkgs}: let
  testPkgs = pkgs // {nvidiaCustomForKernel = kernelPackages: kernelPackages.nvidiaPackages.production;};
  evaluate = settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      pkgs = testPkgs;
      modules = [../hardware/nvidia.nix {system.stateVersion = "26.05";} settings];
    }).config;
  defaults = evaluate {};
  overridden = evaluate {hardware.nvidia.powerManagement.kernelSuspendNotifier = true;};
in
  assert defaults.hardware.nvidia.open;
  assert defaults.hardware.nvidia.powerManagement.enable;
  assert defaults.hardware.nvidia.powerManagement.finegrained;
  assert !defaults.hardware.nvidia.powerManagement.kernelSuspendNotifier;
  assert defaults.systemd.services ? nvidia-suspend;
  assert defaults.systemd.services ? nvidia-resume;
  assert defaults.systemd.services ? nvidia-hibernate;
  assert overridden.hardware.nvidia.powerManagement.kernelSuspendNotifier;
  assert !(overridden.systemd.services ? nvidia-suspend);
    pkgs.runCommand "hardware-nvidia-module-test" {} ''
      touch "$out"
    ''
