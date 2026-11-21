{kernelPackages}: let
  source = (import ./sources.nix).nvidia;
in
  kernelPackages.nvidiaPackages.mkDriver {
    inherit (source) version sha256_64bit openSha256 settingsSha256 persistencedSha256;
  }
