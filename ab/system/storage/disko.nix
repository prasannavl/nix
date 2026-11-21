{lib}: rec {
  optionalPartitionUuid = spec:
    lib.optionalAttrs (spec ? partUuid && spec.partUuid != null) {
      uuid = spec.partUuid;
    };

  optionalPartitionType = spec:
    lib.optionalAttrs (spec ? partitionType && spec.partitionType != null) {
      type = spec.partitionType;
    };

  optionalAttrsNotNull = attrs:
    lib.filterAttrs (_: value: value != null) attrs;

  mkFilesystemContent = {
    format,
    mountpoint,
    mountOptions ? [],
    extraArgs ? [],
  }: {
    type = "filesystem";
    format = format;
    extraArgs = extraArgs;
    mountpoint = mountpoint;
    mountOptions = mountOptions;
  };

  mkFilesystem = {
    size ? "100%",
    partUuid ? null,
    partitionType ? null,
    format,
    mountpoint,
    mountOptions ? [],
    extraArgs ? [],
  }:
    {
      size = size;
      content = mkFilesystemContent {
        inherit format mountpoint mountOptions extraArgs;
      };
    }
    // optionalPartitionType {partitionType = partitionType;}
    // optionalPartitionUuid {partUuid = partUuid;};

  mkExt4 = {
    size ? "100%",
    partUuid ? null,
    partitionType ? null,
    label ? null,
    mountpoint,
    mountOptions ? [],
    extraArgs ? [],
  }:
    mkFilesystem {
      inherit size partUuid partitionType mountpoint mountOptions;
      format = "ext4";
      extraArgs = lib.optionals (label != null) ["-L" label] ++ extraArgs;
    };

  mkExt4Boot = {
    size ? "1G",
    partUuid ? null,
    partitionType ? null,
    label ? "boot",
    mountpoint ? "/boot",
    mountOptions ? [],
    extraArgs ? [],
  }:
    mkExt4 {
      inherit size partUuid partitionType label mountpoint mountOptions extraArgs;
    };

  mkEsp = {
    size ? "1G",
    partUuid ? null,
    label ? null,
    mountpoint ? "/boot",
    mountOptions ? ["fmask=0077" "dmask=0077"],
    extraArgs ? [],
  }:
    mkFilesystem {
      inherit size partUuid mountpoint mountOptions;
      partitionType = "EF00";
      format = "vfat";
      extraArgs = lib.optionals (label != null) ["-n" label] ++ extraArgs;
    };

  mkBiosBootPartition = {
    size ? "1M",
    partUuid ? null,
  }:
    {
      size = size;
      type = "EF02";
    }
    // optionalPartitionUuid {partUuid = partUuid;};

  mkEfiBoot = spec: {
    boot =
      spec.boot or (mkEsp spec);
  };

  mkBiosBoot = {
    biosBoot ? {},
    boot ? mkExt4Boot {},
  }: {
    biosBoot = mkBiosBootPartition biosBoot;
    boot = boot;
  };

  mkBoot = {mode ? "efi", ...} @ spec:
    if mode == "efi" || mode == "uefi"
    then mkEfiBoot (builtins.removeAttrs spec ["mode"])
    else if mode == "bios"
    then mkBiosBoot (builtins.removeAttrs spec ["mode"])
    else throw "diskoLib.mkBoot: unsupported boot mode `${mode}`; expected `efi` or `bios`.";

  mkLuks = {
    size ? "100%",
    partUuid ? null,
    name,
    uuid ? null,
    allowDiscards ? true,
    settings ? {},
    extraFormatArgs ? [],
    extraOpenArgs ? [],
    additionalKeyFiles ? [],
    initrdUnlock ? true,
    askPassword ? null,
    passwordFile ? null,
    keyFile ? null,
    enrollFido2 ? null,
    enrollRecovery ? null,
    extraFido2EnrollArgs ? null,
    content,
  }:
    {
      size = size;
      content =
        {
          type = "luks";
          name = name;
          settings = settings // {inherit allowDiscards;};
          extraFormatArgs = lib.optionals (uuid != null) ["--uuid" uuid] ++ extraFormatArgs;
          extraOpenArgs = extraOpenArgs;
          additionalKeyFiles = additionalKeyFiles;
          initrdUnlock = initrdUnlock;
          content = content;
        }
        // optionalAttrsNotNull {
          askPassword = askPassword;
          passwordFile = passwordFile;
          keyFile = keyFile;
          enrollFido2 = enrollFido2;
          enrollRecovery = enrollRecovery;
          extraFido2EnrollArgs = extraFido2EnrollArgs;
        };
    }
    // optionalPartitionUuid {partUuid = partUuid;};

  mkLuksBtrfs = {
    size ? "100%",
    partUuid ? null,
    name,
    luksUuid ? null,
    allowDiscards ? true,
    settings ? {},
    extraFormatArgs ? [],
    extraOpenArgs ? [],
    additionalKeyFiles ? [],
    initrdUnlock ? true,
    askPassword ? null,
    passwordFile ? null,
    keyFile ? null,
    enrollFido2 ? null,
    enrollRecovery ? null,
    extraFido2EnrollArgs ? null,
    label ? null,
    subvolumes,
  }:
    mkLuks {
      inherit
        size
        partUuid
        name
        allowDiscards
        settings
        extraFormatArgs
        extraOpenArgs
        additionalKeyFiles
        initrdUnlock
        askPassword
        passwordFile
        keyFile
        enrollFido2
        enrollRecovery
        extraFido2EnrollArgs
        ;
      uuid = luksUuid;
      content = {
        type = "btrfs";
        extraArgs = ["-f"] ++ lib.optionals (label != null) ["-L" label];
        subvolumes =
          lib.mapAttrs
          (_: subvolume: {
            mountpoint = subvolume.mountpoint;
            mountOptions = subvolume.mountOptions or [];
          })
          subvolumes;
      };
    };

  mkLuksExt4 = {
    size ? "100%",
    partUuid ? null,
    name,
    uuid ? null,
    allowDiscards ? true,
    settings ? {},
    extraFormatArgs ? [],
    extraOpenArgs ? [],
    additionalKeyFiles ? [],
    initrdUnlock ? true,
    askPassword ? null,
    passwordFile ? null,
    keyFile ? null,
    enrollFido2 ? null,
    enrollRecovery ? null,
    extraFido2EnrollArgs ? null,
    label ? null,
    mountpoint ? "/",
    mountOptions ? [],
    fsExtraArgs ? [],
  }:
    mkLuks {
      inherit
        size
        partUuid
        name
        uuid
        allowDiscards
        settings
        extraFormatArgs
        extraOpenArgs
        additionalKeyFiles
        initrdUnlock
        askPassword
        passwordFile
        keyFile
        enrollFido2
        enrollRecovery
        extraFido2EnrollArgs
        ;
      content = mkFilesystemContent {
        format = "ext4";
        inherit mountpoint mountOptions;
        extraArgs = lib.optionals (label != null) ["-L" label] ++ fsExtraArgs;
      };
    };

  mkMain = {
    diskDevice,
    boot,
    root,
  }: {
    type = "disk";
    device = diskDevice;
    content = {
      type = "gpt";
      partitions =
        boot
        // {
          root = root;
        };
    };
  };
}
