{inputs}: final: prev: let
  system = prev.stdenv.hostPlatform.system;
  package = path:
    import path {
      inherit inputs system;
      pkgs = final;
    };
in {
  voiceTools = {
    voxtype = package ../ext/voxtype;
    whisrs = package ../ext/whisrs;
    vocalinux = package ../ext/vocalinux;
  };
}
