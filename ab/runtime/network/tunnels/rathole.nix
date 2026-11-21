{lib}: {
  mkTunnel = {tunnel}: let
    rathole = tunnel.rathole or tunnel;
  in {
    services.rathole =
      {
        enable = true;
        role =
          rathole.role
          or (throw "rathole tunnel requires rathole.role or role");
        settings =
          rathole.settings
          or (throw "rathole tunnel requires rathole.settings or settings");
      }
      // lib.optionalAttrs (rathole ? package) {
        inherit (rathole) package;
      }
      // lib.optionalAttrs (rathole ? credentialsFile) {
        inherit (rathole) credentialsFile;
      };
  };
}
