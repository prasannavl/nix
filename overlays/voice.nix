{inputs}: final: prev: let
  system = prev.stdenv.hostPlatform.system;
  package = path:
    import path {
      inherit inputs system;
      pkgs = final;
    };
in {
  voiceTools = {
    voxtype = package ../lib/ext/voxtype;
    whisrs = package ../lib/ext/whisrs;
    vocalinux = package ../lib/ext/vocalinux;
  };
}
