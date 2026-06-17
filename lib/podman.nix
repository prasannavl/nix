{
  config,
  lib,
  pkgs,
  ...
}: let
  podmanInContainer = config.boot.isContainer && config.virtualisation.podman.enable;
in {
  config = lib.mkMerge [
    {
      virtualisation.containers = {
        enable = true;
        containersConf.settings.engine.compose_warning_logs = lib.mkDefault false;
      };

      virtualisation.podman = {
        enable = lib.mkDefault true;
        dockerCompat = lib.mkDefault true;
        defaultNetwork.settings.dns_enabled = lib.mkDefault true;
      };
    }

    (lib.mkIf podmanInContainer {
      environment.systemPackages = [
        pkgs.fuse-overlayfs
      ];

      # Incus mount syscall interception hides fsopen/fsconfig from the guest so
      # older mount(8)-style workloads fall back to mount(2). systemd 260 uses the
      # new mount API while preparing service credentials, so that interception
      # breaks core units with status=243/CREDENTIALS in our LXC guests. Keep mount
      # interception off at the Incus layer and make Podman use FUSE overlay
      # storage instead of asking the guest kernel for overlayfs mounts.
      virtualisation.containers.storage.settings.storage.options.overlay.mount_program =
        lib.mkDefault "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs";
    })
  ];
}
