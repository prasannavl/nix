{...}: {
  imports = [../../../lib/services/kache];

  services.kache = {
    enable = true;
    # not inherited by sandboxed nix build
    rustcWrapper = true;
    daemon.enable = true;
    settings.cache.local_max_size = "150GB";
  };
}
