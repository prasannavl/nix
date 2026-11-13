{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [inputs.dotlink.nixosModules.default];

  # Launch directory is the access root for relative grants; keep it present
  # even before the first checkout exists.
  systemd.tmpfiles.rules = [
    "d /home/pvl/spaces/abird 0755 pvl pvl -"
  ];

  services.dotlink = {
    enable = true;
    user = "pvl";
    workingDirectory = "/home/pvl/spaces/abird/";

    # Profile mode: grants/transports from pvl's profile, policy via DOTLINK_*.
    environment = {
      DOTLINK_VERBOSITY = "tools";
      DOTLINK_ALLOW_SHELL = "1";
      DOTLINK_ALLOW_NIX_DAEMON = "1";
      DOTLINK_ALLOW_NIX_CONFIG = "1";
      DOTLINK_ALLOW_GIT_CONFIG = "1";
      DOTLINK_ALLOW_SSH_AGENT = "1";
      DOTLINK_ALLOW_KVM = "1";
      # /dev/kvm (AMD-V) plus the AMD iGPU devices/driver resources. This host
      # has no NVIDIA device class.
      DOTLINK_ALLOW_GPU = "amd";
      # All cache kinds rw; missing dirs warn, later caches still covered.
      DOTLINK_CACHES = lib.concatStringsSep "," [
        "cargo-git:rw"
        "cargo-registry:rw"
        "ccache:rw"
        "go-build:rw"
        "go-mod:rw"
        "gradle:rw"
        "maven:rw"
        "npm:rw"
        "pip:rw"
        "pnpm:rw"
        "sccache:rw"
        "uv:rw"
        "yarn:rw"
      ];
    };

    # Profile mode: PATH/groups not derivable; declare here.
    extraPackages = with pkgs; [git nix openssh];
    extraGroups = ["kvm" "render" "video"];
  };
}
