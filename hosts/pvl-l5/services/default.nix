{...}: {
  imports = [
    ./ai.nix
    ./llama-router.nix
    ./ollama.nix
    ./openwebui.nix
  ];

  services.podman-compose.pvl = {
    backend = "compose";
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
