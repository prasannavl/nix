{pkgs, ...}: {
  virtualisation.incus = {
    enable = true;
    package = pkgs.incus;
    ui.enable = true;
  };
}
