{core}:
assert core.name == "ab-core"; let
  modules = {
    boot = ./boot/default.nix;
    hardware = ./hardware/default.nix;
    kernel = ./kernel/default.nix;
    networkManaged = ./network/managed.nix;
    nixLd = ./nix/ld.nix;
    options = ./options.nix;
    security = ./security/default.nix;
    ssh = ./security/openssh.nix;
    sudo = ./security/sudo.nix;
    swapAuto = ./storage/swap-auto.nix;
    systemd = ./systemd.nix;
    users = ./users.nix;
    neovim = ./profiles/neovim.nix;
    gpg = ./security/gpg.nix;
    mdns = ./network/mdns.nix;
    networkWifi = ./network/wifi.nix;
    desktop = {
      audio = ./desktop/audio.nix;
      base = ./desktop/base.nix;
      flatpak = ./desktop/flatpak.nix;
      gdm = ./desktop/gdm.nix;
      gdmRdp = ./desktop/gdm-rdp.nix;
      gnome = ./desktop/gnome.nix;
      keyd = ./desktop/keyd.nix;
      power = ./desktop/power.nix;
      printing = ./desktop/printing.nix;
      seatd = ./desktop/seatd.nix;
      wm = profiles.mkWmModule {};
    };
    sysctl = {
      coredump = ./kernel/sysctl/coredump.nix;
      inotify = ./kernel/sysctl/inotify.nix;
      panic = ./kernel/sysctl/panic.nix;
      sysrq = ./kernel/sysctl/sysrq.nix;
      vm = ./kernel/sysctl/vm.nix;
    };
  };

  installer = {
    buildImage = import ./installer/build-image.nix;
    images = import ./installer/images.nix;
    module = import ./installer/module.nix;
    persistence = import ./installer/persistence.nix;
    storageOverride = import ./installer/storage-override.nix;
    scripts = {
      builder = ./installer/builder.sh;
      genericInstallHelp = ./installer/generic-install-help.sh;
      installerToDisk = ./installer/installer-to-disk.sh;
      offlineInstall = ./installer/offline-install.sh;
      persistence = ./installer/persistence.sh;
    };
  };

  nix = {
    gcCoordinationModule = ./nix/gc-coordination.nix;
    guardedGc = args: import ./nix/guarded-gc.nix args;
    module = import ./nix/default.nix;
  };

  profiles = {
    mkWmModule = import ./desktop/wm.nix;
    incusGuest = import ./profiles/incus-guest.nix;
    vm = import ./profiles/vm.nix;
  };

  storage = {
    disko = {lib}: import ./storage/disko.nix {inherit lib;};
    diskoModule = import ./storage/disko-module.nix;
  };

  hardware = {
    desktop = ./hardware/desktop.nix;
    logitech = ./hardware/logitech.nix;
    mt7921e = ./hardware/mt7921e.nix;
    openrgb = ./hardware/openrgb.nix;
    tpm = ./hardware/tpm.nix;
    devices = {
      asusFa401wv = ./hardware/devices/asus-fa401wv.nix;
      gmtekEvoX2 = ./hardware/devices/gmtek-evo-x2.nix;
      lenovoLegion5 = ./hardware/devices/lenovo-legion-5-15ach6h.nix;
    };
    amdgpuStrix = ./hardware/amdgpu-strix.nix;
    mesa = ./hardware/mesa.nix;
    nvidia = ./hardware/nvidia.nix;
  };

  mk = {pkgs}: {
    inherit hardware installer modules nix profiles;
    storage = storage // {disko = storage.disko {lib = pkgs.lib;};};
  };

  extension = {
    pkgs,
    ab,
  }:
    assert builtins.isAttrs ab; {
      system = mk {inherit pkgs;};
    };
in {
  name = "ab-system";
  dependencies = {
    required = ["core"];
    optional = [];
  };

  inherit extension hardware installer mk modules nix profiles storage;
}
