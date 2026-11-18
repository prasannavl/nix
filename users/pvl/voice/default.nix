{
  nixos = {...}: {
    # Text injection only. Evdev global key capture needs the much broader
    # input group; use compositor shortcuts instead.
    hardware.uinput.enable = true;
    users.users.pvl.extraGroups = ["uinput"];
  };

  home = {pkgs, ...}: let
    voice = pkgs.voiceTools;
  in {
    # Install all three without auto-starting competing microphone daemons.
    # Whisper prefers Vulkan; ONNX CPU handles Parakeet and Cohere.
    home.packages = [
      voice.voxtype.vulkan
      voice.voxtype.onnxCpu
      voice.whisrs.vulkan
      voice.vocalinux.vulkan
    ];
  };
}
