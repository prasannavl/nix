{
  admins,
  scope ? null,
  machines,
}: let
  inherit (machines) pvl-x2;
  secretsLib = import ../../../lib/flake/secrets.nix;
  secrets = secretsLib.mkStack {
    base = "data/secrets/pvl";
    inherit scope;
  };
  serviceSecrets = import ./services.nix {
    inherit admins machines secrets;
  };
in
  serviceSecrets
  // {
    # Shared CA
    ${secrets.file "ca/ca.crt.age"}.publicKeys = admins ++ pvl-x2;
    ${secrets.file "ca/ca.key.age"}.publicKeys = admins;
  }
