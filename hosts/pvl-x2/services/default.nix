{...}: {
  imports = [
    ./audiobookshelf
    ./beszel
    ./dockge.nix
    ./docmost
    ./feishin
    ./immich
    ./jellyfin
    ./kavita
    ./media.nix
    ./memos
    ./navidrome
    ./nginx.nix
    ./ollama
    ./openwebui
    ./paperless
    ./portainer
    ./shadowsocks
    ./stirling-pdf
    ./vaultwarden
    ./postgres.nix
  ];

  config.services.podman-compose.pvl = {
    backend = "compose";
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
