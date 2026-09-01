{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  isSizedSwapFile = swap: swap.size != null && !swap.isDevice;
  swapsByMount = lib.groupBy (swap: builtins.dirOf swap.device) (
    lib.filter isSizedSwapFile config.swapDevices
  );
  isBtrfsSwapFileSystem = mountPoint: fileSystem:
    fileSystem.fsType == "btrfs" && builtins.hasAttr mountPoint swapsByMount;
  btrfsSwapFileSystems = lib.filterAttrs isBtrfsSwapFileSystem config.fileSystems;

  isSafeSubvolumeName = name:
    builtins.isString name
    && !builtins.elem name ["." ".."]
    && builtins.match "^[A-Za-z0-9@_+.-]+$" name != null;
  isSupportedDevicePath = device:
    builtins.isString device && lib.hasPrefix "/dev/" device;

  mkSwapMount = mountPoint: fileSystem: let
    swaps = swapsByMount.${mountPoint};
    subvolumeOptions = lib.filter (lib.hasPrefix "subvol=") fileSystem.options;
    subvolume =
      if builtins.length subvolumeOptions == 1
      then lib.removePrefix "subvol=" (builtins.head subvolumeOptions)
      else null;
    unitStem = utils.escapeSystemdPath mountPoint;
    deviceUnit = "${utils.escapeSystemdPath fileSystem.device}.device";
  in {
    inherit fileSystem mountPoint subvolume swaps deviceUnit;
    mountUnit = "${unitStem}.mount";
    serviceName = "prepare-btrfs-swap-subvolume-${unitStem}";
    swapUnits = map (swap: "${utils.escapeSystemdPath swap.realDevice}.swap") swaps;
  };

  swapMounts = lib.mapAttrsToList mkSwapMount btrfsSwapFileSystems;
  isProvisionableSwapMount = swapMount:
    swapMount.fileSystem.enable
    && isSafeSubvolumeName swapMount.subvolume
    && isSupportedDevicePath swapMount.fileSystem.device;
  provisionableSwapMounts = lib.filter isProvisionableSwapMount swapMounts;

  mkAssertions = {
    fileSystem,
    mountPoint,
    subvolume,
    swaps,
    ...
  }:
    [
      {
        assertion = fileSystem.enable;
        message = ''
          Btrfs swap mount ${mountPoint} must be enabled when it contains a
          sized swap file.
        '';
      }
      {
        assertion = isSafeSubvolumeName subvolume;
        message = ''
          Btrfs swap mount ${mountPoint} must declare exactly one
          single-component subvol= value containing only letters, numbers,
          @, _, +, ., or -.
        '';
      }
      {
        assertion = builtins.elem "nofail" fileSystem.options;
        message = ''
          Btrfs swap mount ${mountPoint} must include nofail so a
          provisioning failure cannot block boot or remote recovery.
        '';
      }
      {
        assertion = isSupportedDevicePath fileSystem.device;
        message = ''
          Btrfs swap mount ${mountPoint} must use a device path below /dev so
          subvolume preparation can order itself after its systemd device unit.
        '';
      }
    ]
    ++ map (swap: {
      assertion = builtins.elem "nofail" swap.options;
      message = ''
        Swap file ${swap.device} must include nofail so an unavailable swap file
        cannot block boot or remote recovery.
      '';
    })
    swaps;

  mkPrepareService = {
    fileSystem,
    mountUnit,
    serviceName,
    subvolume,
    deviceUnit,
    ...
  }:
    lib.nameValuePair serviceName {
      description = "Prepare Btrfs swap subvolume ${subvolume}";
      requiredBy = [mountUnit];
      before = [mountUnit "shutdown.target"];
      # The backing device may appear during stage 2 (for example a
      # systemd-cryptsetup resource unlocked after initrd). Pull and order the
      # device unit explicitly so the private top-level mount cannot race it.
      after = ["systemd-remount-fs.service" deviceUnit];
      wants = [deviceUnit];
      conflicts = ["shutdown.target"];
      path = [pkgs.btrfs-progs pkgs.util-linux];
      environment = {
        BTRFS_DEVICE = fileSystem.device;
        BTRFS_SUBVOLUME = subvolume;
      };
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        PrivateMounts = true;
        RuntimeDirectory = serviceName;
        TimeoutStartSec = "2min";
        UMask = "0077";
      };
      script = ''
        mount_path="/run/${serviceName}"
        subvolume_path="$mount_path/$BTRFS_SUBVOLUME"

        mount --types btrfs --options subvolid=5 -- "$BTRFS_DEVICE" "$mount_path"

        if btrfs subvolume show "$subvolume_path" >/dev/null 2>&1; then
          echo "Btrfs subvolume $BTRFS_SUBVOLUME already exists"
        elif [ -e "$subvolume_path" ]; then
          echo "$subvolume_path exists but is not a Btrfs subvolume" >&2
          exit 1
        else
          btrfs subvolume create "$subvolume_path"
        fi
      '';
    };

  provisionableSwapUnits = lib.concatMap (swapMount: swapMount.swapUnits) provisionableSwapMounts;
in {
  assertions = lib.concatMap mkAssertions swapMounts;
  systemd.services = lib.listToAttrs (map mkPrepareService provisionableSwapMounts);
  systemd.targets.btrfs-swap-auto = lib.mkIf (provisionableSwapUnits != []) {
    description = "Automatic Btrfs swap provisioning";
    wantedBy = ["multi-user.target"];
    wants = provisionableSwapUnits;
  };
}
