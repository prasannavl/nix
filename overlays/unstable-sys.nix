{ inputs }:
final: prev:
let
  unstablePkgs = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config // { allowUnfree = true; };
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
  mkMultiLibOverlay = pkgs: builtins.listToAttrs (map (name: {
    inherit name;
    value = pkgs.${name};
  }) multiLibPkgs);
  multilibOverlay = mkMultiLibOverlay unstablePkgs;
  multilibOverlay32 = mkMultiLibOverlay unstablePkgs.pkgsi686Linux;
  mkCrossOverlay = builtins.mapAttrs (name: crossPkgs:
    if builtins.hasAttr name unstablePkgs.pkgsCross
    then crossPkgs // mkMultiLibOverlay unstablePkgs.pkgsCross.${name}
    else crossPkgs
  );
in
lib.foldl' (acc: attrs: acc // attrs) {} [
  { unstable = unstablePkgs; }

  # Kernel from unstable.
  # {
  #   linuxPackages = unstablePkgs.linuxPackages;
  #   linuxPackages_latest = unstablePkgs.linuxPackages_latest;
  # }

  # Firmware from unstable.
  # { linux-firmware = unstablePkgs.linux-firmware; }

  # Cross-compilation overlays if needed
  # { pkgsCross = mkCrossOverlay prev.pkgsCross; }

  # 32-bit override only for the selected graphics stack.
  # { pkgsi686Linux = prev.pkgsi686Linux // multilibOverlay32; }

  # Mesa / OpenGL / Vulkan stack from unstable.
  # multilibOverlay
]
