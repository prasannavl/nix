{...}: {
  imports = [
    ./ollama
    ./openwebui
  ];

  config.services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
