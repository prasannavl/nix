{...}: {
  imports = [
    ./ollama.nix
    ./openwebui.nix
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
  ];

  services.podman-compose.pvl = {
    backend = "compose";
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
