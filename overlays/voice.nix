{inputs}: final: prev: let
  system = prev.stdenv.hostPlatform.system;
  package = path:
    import path {
      inherit inputs system;
      pkgs = final;
    };
in {
  voiceTools = {
    voxtype = package ../nix/ext/voxtype;
    whisrs = package ../nix/ext/whisrs;
    vocalinux = package ../nix/ext/vocalinux;
  };
}
