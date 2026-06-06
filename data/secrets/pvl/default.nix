{
  admins,
  machines,
}: let
  secretsLib = import ../../../lib/flake/secrets.nix;
  secrets = secretsLib.mkStack {
    base = "data/secrets/pvl";
  };
  serviceSecrets = import ./services.nix {
    inherit admins machines secrets;
  };
in
  serviceSecrets
