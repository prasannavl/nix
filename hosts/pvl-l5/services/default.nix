{...}: {
  imports = [
    ./ollama.nix
    ./openwebui.nix
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
  ];

  services.podman-compose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
