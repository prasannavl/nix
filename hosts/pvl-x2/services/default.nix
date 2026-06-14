{...}: {
  imports = [
    ./beszel
    ./dockge.nix
    ./docmost
    ./immich
    ./memos
    ./nginx.nix
    ./ollama
    ./openwebui
    ./portainer
    ./shadowsocks
    ./vaultwarden
    ./postgres.nix
  ];

  config.services.podman-compose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
