{...}: {
  hardware.amdgpu.initrd.enable = true;

  boot.kernelParams = [
    "amdgpu.dcdebugmask=0x10"
  ];
}
