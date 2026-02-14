{...}: {
  hardware.amdgpu.initrd.enable = true;

  boot.kernelParams = [
    "amdgpu.dcdebugmask=0x10"
  ];

  boot.initrd.kernelModules = ["amdgpu"];
  boot.kernelModules = ["amdgpu"];
}
