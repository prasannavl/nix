{
  admins,
  machines,
}: let
  inherit (machines) pvl-x2;
  secrets = rec {
    base = "data/secrets";
    service = name: "${base}/services/${name}";
    key = serviceName: secretName: "${service serviceName}/${secretName}.key.age";
  };
in {
  # Services
  ${secrets.key "beszel" "key"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "beszel" "token"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "docmost" "app-secret"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "docmost" "database-url"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "docmost" "postgres-password"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "immich" "db-password"}.publicKeys = admins ++ pvl-x2;
  ${secrets.key "shadowsocks" "password"}.publicKeys = admins ++ pvl-x2;
}
