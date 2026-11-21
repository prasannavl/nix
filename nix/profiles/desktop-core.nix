{...}: {
  imports = [
    ./core.nix
    ../../ab/system/desktop/audio.nix
    ../../ab/system/desktop/base.nix
    ./policy/wm.nix
    ../../ab/system/security/gpg.nix
    ../../ab/system/network/mdns.nix
  ];

  programs.seahorse.enable = true;
  programs.firefox.enable = true;
}
