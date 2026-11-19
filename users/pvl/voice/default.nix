{
  nixos = {...}: {
    # Text injection only. Evdev global key capture needs the much broader
    # input group; use compositor shortcuts instead.
    hardware.uinput.enable = true;
    users.users.pvl.extraGroups = ["uinput"];
  };

  home = {
    osConfig,
    pkgs,
    ...
  }: let
    voice = pkgs.voiceTools;

    # Accelerator these hosts run. Vulkan is qualified on every GPU in the fleet
    # (NVIDIA, RADV, Radeon iGPU), falls back to the CPU inside the same binary,
    # and keeps CUDA/ROCm toolchains out of the desktop closure. Move a host
    # here after building and timing that variant on it.
    accelByHost = {
      pvl-a1 = "vulkan"; # RTX 4060 Laptop + Radeon 890M
      pvl-l5 = "vulkan"; # RTX 3060 Laptop + AMD iGPU
      pvl-x2 = "vulkan"; # Radeon iGPU
    };
    accel = accelByHost.${osConfig.networking.hostName} or "vulkan";
  in {
    # One binary per tool, nothing auto-starts competing microphone daemons.
    # Vocalinux ships Vulkan-only pywhispercpp and picks Vulkan, then CUDA, then
    # the CPU by itself at model load.
    home.packages = [
      voice.voxtype.accel.${accel}
      voice.whisrs.accel.${accel}
      voice.vocalinux.vulkan
    ];
  };
}
