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
  ];

  config.services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
