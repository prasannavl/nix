{
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
  ];

  # Image-specific trim for container builds.
  documentation.enable = false;
  boot.enableContainers = false;

  services.getty.autologinUser = null;
}
