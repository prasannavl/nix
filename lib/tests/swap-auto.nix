{pkgs}: let
  lib = pkgs.lib;
  evalConfig = module:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      pkgs = pkgs;
      modules = [../swap-auto.nix module];
    };
  mkConfig = {
    mountEnabled ? true,
    mountDevice ? "/dev/mapper/root",
    mountOptions ? ["subvol=@swap" "nofail"],
    swapOptions ? ["nofail"],
  }: {
    fileSystems = {
      "/" = {
        device = "/dev/vda";
        fsType = "ext4";
      };
      "/swap" = {
        device = mountDevice;
        enable = mountEnabled;
        fsType = "btrfs";
        options = mountOptions;
      };
    };
    swapDevices = [
      {
        device = "/swap/swap0";
        size = 1024;
        options = swapOptions;
      }
    ];
  };

  valid = evalConfig (mkConfig {});
  invalidDisabledMount = evalConfig (mkConfig {mountEnabled = false;});
  invalidSubvolume = evalConfig (mkConfig {mountOptions = ["subvol=@swap/nested" "nofail"];});
  invalidMount = evalConfig (mkConfig {mountOptions = ["subvol=@swap"];});
  invalidSwap = evalConfig (mkConfig {swapOptions = [];});
  invalidTaggedDevice = evalConfig (mkConfig {mountDevice = "LABEL=swap";});
  invalidRegularFile = evalConfig (mkConfig {mountDevice = "/var/lib/swap.btrfs";});
  failsToBuild = evaluated: !(builtins.tryEval evaluated.config.system.build.toplevel).success;
  service = valid.config.systemd.services.prepare-btrfs-swap-subvolume-swap;
  target = valid.config.systemd.targets.btrfs-swap-auto;
in
  assert service.requiredBy == ["swap.mount"];
  assert service.before == ["swap.mount" "shutdown.target"];
  assert service.after == ["systemd-remount-fs.service" "dev-mapper-root.device"];
  assert service.wants == ["dev-mapper-root.device"];
  assert service.unitConfig.DefaultDependencies == false;
  assert service.serviceConfig.PrivateMounts == true;
  assert lib.hasInfix "subvolid=5" service.script;
  assert lib.hasInfix "btrfs subvolume create" service.script;
  assert target.wantedBy == ["multi-user.target"];
  assert target.wants == ["swap-swap0.swap"];
  assert failsToBuild invalidDisabledMount;
  assert failsToBuild invalidSubvolume;
  assert failsToBuild invalidMount;
  assert failsToBuild invalidSwap;
  assert failsToBuild invalidTaggedDevice;
  assert failsToBuild invalidRegularFile;
    pkgs.runCommand "swap-auto-module-test" {} ''
      touch "$out"
    ''
