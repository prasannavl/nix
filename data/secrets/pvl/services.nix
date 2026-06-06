{
  admins,
  machines,
  secrets,
}: let
  inherit (machines) pvl-x2;
in {
  ${secrets.serviceKey "beszel" "key"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "beszel" "token"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "docmost" "app-secret"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "docmost" "database-url"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "docmost" "postgres-password"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "immich" "db-password"}.publicKeys = admins ++ pvl-x2;
  ${secrets.serviceKey "shadowsocks" "password"}.publicKeys = admins ++ pvl-x2;
}
