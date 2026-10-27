{...}: {
  imports = [
    ./ai.nix
    ./audiobookshelf
    ./beszel
    ./dockge.nix
    ./docmost
    ./dotlink.nix
    ./feishin
    ./immich
    ./jellyfin
    ./kavita
    ./librechat.nix
    ./llama-router.nix
    ./media.nix
    ./memos
    ./navidrome
    ./nginx.nix
    ./ollama
    ./opendesign.nix
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
