{inputs}: final: prev: let
  unstable = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config;
  };
  lib = prev.lib;
  multiLibPkgs = [
    "mesa"
    "mesa-demos"
    "libglvnd"
    "libva"
    "libva-utils"
    "libva-vdpau-driver"
    "libvdpau-va-gl"
    "nvidia-vaapi-driver"
    "vulkan-loader"
    "vulkan-tools"
  ];
  mkMultiLibOverlay = pkgs:
    builtins.listToAttrs (map (name: {
        inherit name;
        value = pkgs.${name};
      })
      multiLibPkgs);
  multilibOverlay = mkMultiLibOverlay unstable;
  multilibOverlay32 = mkMultiLibOverlay unstable.pkgsi686Linux;
  mkCrossOverlay = builtins.mapAttrs (
    name: crossPkgs:
      if builtins.hasAttr name unstable.pkgsCross
      then crossPkgs // mkMultiLibOverlay unstable.pkgsCross.${name}
      else crossPkgs
  );
in
  lib.foldl' (acc: attrs: acc // attrs) {} [
    #
    # Note that these will trigger an overall world rebuild
    # since it's in the lowest part of the DAG.
    #
    # Kernel from unstable.
    # {
    #   linuxPackages = unstable.linuxPackages;
    #   linuxPackages_latest = unstable.linuxPackages_latest;
    # }

    # Firmware from unstable.
    # { linux-firmware = unstable.linux-firmware; }

    # Cross-compilation overlays if needed
    # { pkgsCross = mkCrossOverlay prev.pkgsCross; }

    # 32-bit override only for the selected graphics stack.
    # { pkgsi686Linux = prev.pkgsi686Linux // multilibOverlay32; }

    # Mesa / OpenGL / Vulkan stack from unstable.
    # multilibOverlay
  ]
