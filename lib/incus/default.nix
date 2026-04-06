{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.incusMachines;

  defaultBaseImage = inputs.self.nixosImages.incus-base;
  defaultBaseAlias = "nixos-incus-base";

  hasInstances = cfg.instances != {};

  helperPackage = pkgs.writeShellApplication {
    name = "incus-machines-helper";
    excludeShellChecks = ["SC1091" "SC2016"];
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      source ${./helper.sh}
      main "$@"
    '';
  };
  helperScript = "${helperPackage}/bin/incus-machines-helper";

  reconcilerCommand = pkgs.writeShellScriptBin "incus-machines-reconciler" ''
    export INCUS_MACHINES_RECONCILE_MODE=${lib.escapeShellArg cfg.reconcilePolicy}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    exec ${helperScript} reconciler "$@"
  '';

  settlementCommand = pkgs.writeShellScriptBin "incus-machines-settlement" ''
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_IPV4_ADDRESSES=${lib.escapeShellArg instanceIpv4AddressesJson}
    export INCUS_MACHINES_INSTANCE_SSH_PORTS=${lib.escapeShellArg instanceSshPortsJson}
    export INCUS_MACHINES_INSTANCE_WAIT_FOR_SSH=${lib.escapeShellArg instanceWaitForSshJson}
    exec ${helperScript} settlement "$@"
  '';

  sanitizeImageAlias = value:
    builtins.replaceStrings
    [
      ":"
      "/"
      " "
      "."
      "_"
    ]
    [
      "-"
      "-"
      "-"
      "-"
      "-"
    ]
    value;

  deviceType = lib.types.submodule (_: {
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        default = "disk";
        description = "Device type: disk (default), gpu, unix-char, nic, etc.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source path (host dir, volume name, or device path).";
      };
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Mount/device path inside the container.";
      };
      shift = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable UID/GID shift for disk mounts.";
      };
      pool = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Storage pool for volume-backed disk devices.";
      };
      removalPolicy = lib.mkOption {
        type = lib.types.enum ["keep" "delete"];
        default = "keep";
        description = "For disk devices: 'delete' wipes the source dir on container delete-all; 'keep' (default) preserves it.";
      };
      extraProperties = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional incus device properties not covered by top-level fields.";
      };
    };
  });

  machineType = lib.types.submodule (_: {
    options = {
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = ''
          Optional image source for this machine. A string is treated as an
          Incus image reference such as `debian` or `images:debian/12`; a
          non-string value is treated as a NixOS image derivation/system attrset
          to import into local Incus. Defaults to
          `services.incusMachines.defaultImage`.
        '';
      };
      imageAlias = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional stable Incus alias for this machine's image. Defaults to the
          shared default alias when `image` is unset, otherwise
          `nixos-incus-<machine-name>` for local NixOS images and a sanitized
          alias derived from the remote image reference for string images.
        '';
      };
      ipv4Address = lib.mkOption {
        type = lib.types.str;
        description = "Static IPv4 address (outside the bridge DHCP range).";
      };
      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = "SSH port used by readiness settle checks for this guest.";
      };
      waitForSsh = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether settle should wait for TCP reachability on `sshPort` for this
          guest. Disable this for containers that are intentionally not managed
          over SSH.
        '';
      };
      devices = lib.mkOption {
        type = lib.types.attrsOf deviceType;
        default = {};
        description = "Incus devices attached to this container.";
      };
      config = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Incus container config keys. Changes trigger stop+delete+recreate.";
      };
      removalPolicy = lib.mkOption {
        type = lib.types.enum ["stop-only" "delete-container" "delete-all"];
        default = "delete-container";
        description = "What happens when this machine is removed from config.";
      };
      bootTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Bump to force a restart (stop+start) on next rebuild.";
      };
      recreateTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Bump to force a full recreate (stop+delete+create) on next rebuild.";
      };
    };
  });

  isHostPath = source: source != null && lib.hasPrefix "/" source;
  isHostPathDisk = dev: dev.type == "disk" && isHostPath dev.source;
  isManagedHostDir = dev: isHostPathDisk dev && !lib.hasPrefix "/dev/" dev.source;
  isVolumeBackedDisk = dev: dev.type == "disk" && dev.source != null && !isHostPath dev.source;

  resolveDeviceProperties = _name: dev: let
    base = {inherit (dev) type;};
    withSource = lib.optionalAttrs (dev.source != null) {inherit (dev) source;};
    withPath = lib.optionalAttrs (dev.path != null) {inherit (dev) path;};
    withShift = lib.optionalAttrs (dev.type == "disk" && dev.shift) {shift = "true";};
    withPool = lib.optionalAttrs (isVolumeBackedDisk dev) {inherit (dev) pool;};
  in
    base // withSource // withPath // withShift // withPool // dev.extraProperties;

  createOnlyDevices = machine:
    lib.filterAttrs (_: dev: dev.type != "disk") machine.devices;
  syncableDevices = machine:
    lib.filterAttrs (_: dev: dev.type == "disk") machine.devices;

  configHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON {
      preseedTag = cfg.preseedTag;
      inherit (machine) config;
      image = let
        resolvedImage = resolveMachineImage name machine;
      in {
        inherit (resolvedImage) alias createRef;
      };
      createOnlyDevices = lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine);
    });

  diskDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (syncableDevices machine));

  diskGcMetadataJson = machine:
    builtins.toJSON (
      lib.mapAttrs
      (_: dev:
        {
          inherit (dev) removalPolicy;
        }
        // lib.optionalAttrs (isManagedHostDir dev) {inherit (dev) source;})
      (syncableDevices machine)
    );

  createOnlyDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs resolveDeviceProperties (createOnlyDevices machine));

  mkUserMetadata = name: machine:
    {
      "user.managed-by" = "nixos";
      "user.config-hash" = configHash name machine;
      "user.boot-tag" = machine.bootTag;
      "user.recreate-tag" = machine.recreateTag;
      "user.removal-policy" = machine.removalPolicy;
    }
    // lib.concatMapAttrs (
      devName: dev:
        lib.optionalAttrs (dev.type == "disk") {
          "user.device.${devName}.removal-policy" = dev.removalPolicy;
        }
        // lib.optionalAttrs (isManagedHostDir dev) {
          "user.device.${devName}.source" = dev.source;
        }
    )
    machine.devices;

  resolveMachineImage = name: machine: let
    image =
      if machine.image != null
      then machine.image
      else cfg.defaultImage;
    isRemote = builtins.isString image;
    remoteRef =
      if isRemote
      then
        if lib.hasInfix ":" image
        then image
        else "images:${image}"
      else null;
    alias =
      if machine.imageAlias != null
      then machine.imageAlias
      else if machine.image != null
      then
        if isRemote
        then "incus-${sanitizeImageAlias remoteRef}"
        else "nixos-incus-${name}"
      else cfg.defaultImageAlias;
  in
    if isRemote
    then {
      kind = "remote";
      inherit alias remoteRef;
      createRef = "local:${alias}";
      imageIdentity = "remote:${remoteRef}";
    }
    else let
      imageLabel = image.config.system.nixos.label;
      imageSystem = image.pkgs.stdenv.hostPlatform.system;
      imageFile = "nixos-image-${imageLabel}-${imageSystem}.tar.xz";
      metadata = image.config.system.build.metadata;
      rootfs = image.config.system.build.tarball;
      metadataFile = "${metadata}/tarball/${imageFile}";
      rootfsFile = "${rootfs}/tarball/${imageFile}";
      imageSource = "${metadataFile}|${rootfsFile}";
    in {
      kind = "local";
      inherit alias imageSource metadataFile rootfsFile;
      createRef = "local:${alias}";
      imageIdentity = "local:${imageSource}";
    };

  instanceImages = lib.mapAttrs resolveMachineImage cfg.instances;

  declaredImages =
    builtins.attrValues
    (lib.mapAttrs'
      (_name: image:
        lib.nameValuePair image.alias image)
      instanceImages);

  aliasToMachineNames =
    lib.foldl'
    (acc: name: let
      alias = instanceImages.${name}.alias;
    in
      acc
      // {
        ${alias} = (acc.${alias} or []) ++ [name];
      })
    {}
    (builtins.attrNames instanceImages);

  duplicateImageAliases =
    lib.attrNames
    (lib.filterAttrs (_alias: machineNames: builtins.length machineNames > 1) aliasToMachineNames);

  imageAliasConflicts =
    lib.filter (
      alias: let
        sources =
          lib.unique
          (map (name: instanceImages.${name}.imageIdentity) aliasToMachineNames.${alias});
      in
        builtins.length sources > 1
    )
    duplicateImageAliases;

  ipv4ToMachineNames =
    lib.foldl'
    (acc: name: let
      ipv4Address = cfg.instances.${name}.ipv4Address;
    in
      acc
      // {
        ${ipv4Address} = (acc.${ipv4Address} or []) ++ [name];
      })
    {}
    (builtins.attrNames cfg.instances);

  duplicateIpv4Addresses =
    lib.attrNames
    (lib.filterAttrs (_ipv4Address: machineNames: builtins.length machineNames > 1) ipv4ToMachineNames);

  ipv4AddressConflicts =
    map
    (ipv4Address: "${ipv4Address} -> ${lib.concatStringsSep ", " ipv4ToMachineNames.${ipv4Address}}")
    duplicateIpv4Addresses;

  declaredImagesJson = builtins.toJSON declaredImages;
  declaredInstancesJson = builtins.toJSON (builtins.attrNames cfg.instances);
  instanceIpv4AddressesJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.ipv4Address) cfg.instances);
  instanceSshPortsJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.sshPort) cfg.instances);
  instanceWaitForSshJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.waitForSsh) cfg.instances);
  incusSwitchStateFile = pkgs.writeText "incus-machines-switch-state.json" (builtins.toJSON {
    preseed = config.virtualisation.incus.preseed;
    imageTag = cfg.imageTag;
    preseedTag = cfg.preseedTag;
    instances =
      lib.mapAttrs
      (name: machine: {
        configHash = configHash name machine;
        bootTag = machine.bootTag;
        recreateTag = machine.recreateTag;
        removalPolicy = machine.removalPolicy;
        image = instanceImages.${name};
        desiredDisks = diskDeviceSpecJson machine;
        desiredDiskGcMetadata = diskGcMetadataJson machine;
      })
      cfg.instances;
  });
  mkEnvAssignment = name: value: "${name}=${lib.escapeShellArg (toString value)}";
  incusLifecycleDeps = [
    "incus-preseed.service"
    "network-online.target"
    "incus-images.service"
  ];

  mkMachineService = name: machine: let
    instanceImage = instanceImages.${name};
    hash = configHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
    createOnlyDevSpec = createOnlyDeviceSpecJson machine;
    userMetaJson = builtins.toJSON (mkUserMetadata name machine);
    configJson = builtins.toJSON machine.config;
  in
    lib.nameValuePair "incus-${name}" {
      description = "Incus container lifecycle for ${name}";
      wantedBy = ["multi-user.target"];
      after = incusLifecycleDeps;
      wants = incusLifecycleDeps;
      requires = [
        "incus-preseed.service"
        "incus-images.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "-${config.virtualisation.incus.package.client}/bin/incus stop ${lib.escapeShellArg name}";
        Environment = [
          (mkEnvAssignment "INCUS_MACHINES_IMAGE_TAG" cfg.imageTag)
          (mkEnvAssignment "INCUS_MACHINES_INSTANCE_NAME" name)
          (mkEnvAssignment "INCUS_MACHINES_INSTANCE_IMAGE" (builtins.toJSON instanceImage))
          (mkEnvAssignment "INCUS_MACHINES_CREATE_REF" instanceImage.createRef)
          (mkEnvAssignment "INCUS_MACHINES_INSTANCE_IPV4_ADDRESS" machine.ipv4Address)
          (mkEnvAssignment "INCUS_MACHINES_DESIRED_CONFIG_HASH" hash)
          (mkEnvAssignment "INCUS_MACHINES_DESIRED_BOOT_TAG" machine.bootTag)
          (mkEnvAssignment "INCUS_MACHINES_DESIRED_RECREATE_TAG" machine.recreateTag)
          (mkEnvAssignment "INCUS_MACHINES_REMOVAL_POLICY" machine.removalPolicy)
          (mkEnvAssignment "INCUS_MACHINES_DESIRED_DISKS" diskDevSpec)
          (mkEnvAssignment "INCUS_MACHINES_DESIRED_DISK_GC_METADATA" diskGcMetadata)
          (mkEnvAssignment "INCUS_MACHINES_CREATE_ONLY_DEVICES" createOnlyDevSpec)
          (mkEnvAssignment "INCUS_MACHINES_USER_META" userMetaJson)
          (mkEnvAssignment "INCUS_MACHINES_INSTANCE_CONFIG" configJson)
        ];
        ExecStart = "${helperScript} machine";
      };
    };

  mkDeviceTmpfiles = _name: machine:
    lib.concatLists (
      lib.mapAttrsToList (
        _devName: dev:
          lib.optional (isManagedHostDir dev)
          "d ${dev.source} 0755 root root -"
      )
      machine.devices
    );
in {
  options.services.incusMachines = {
    defaultImage = lib.mkOption {
      type = lib.types.raw;
      default = defaultBaseImage;
      description = ''
        Default image source used for Incus machines when a machine does not
        set `image`. A string is treated as an Incus image reference; a
        non-string value is treated as a local NixOS image build.
      '';
    };

    defaultImageAlias = lib.mkOption {
      type = lib.types.str;
      default = defaultBaseAlias;
      description = ''
        Shared Incus alias used for `defaultImage`. Machines that set a custom
        `image` default to `nixos-incus-<machine-name>` for local NixOS images
        and a sanitized alias derived from the remote image reference for string
        images unless they also set `imageAlias`.
      '';
    };

    imageTag = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "Bump to force refresh of all declared Incus images on next rebuild.";
    };

    preseedTag = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = ''
        Manual coordination tag for disruptive parent Incus preseed changes.
        Bumping this value folds the parent preseed epoch into every guest's
        recreate hash, forcing declared guests to recreate on their next
        lifecycle run.
      '';
    };

    reconcilePolicy = lib.mkOption {
      type = lib.types.enum ["off" "best-effort" "strict"];
      default = "best-effort";
      description = ''
        Reconcile policy for declared Incus guests. `off` disables guest
        reconcile helpers, `best-effort` retries missing or stopped guests
        without failing the caller, and `strict` makes guest reconcile failures
        abort the caller.
      '';
    };

    autoReconcile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run guest reconcile automatically at boot via
        `incus-machines-reconciler.service`. This is disabled by default so
        host activation and boot do not depend on child guest lifecycle
        convergence.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf machineType;
      default = {};
      description = "Declarative Incus containers with lifecycle management.";
    };
  };

  config = lib.mkIf hasInstances {
    assertions = [
      {
        assertion = imageAliasConflicts == [];
        message =
          "services.incusMachines has conflicting image aliases with different image sources: "
          + lib.concatStringsSep ", " imageAliasConflicts;
      }
      {
        assertion = ipv4AddressConflicts == [];
        message =
          "services.incusMachines has duplicate ipv4Address assignments: "
          + lib.concatStringsSep "; " ipv4AddressConflicts;
      }
    ];

    virtualisation.incus = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault true;
    };

    systemd.tmpfiles.rules =
      lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles cfg.instances);

    environment.systemPackages = [
      reconcilerCommand
      settlementCommand
    ];

    systemd.services = let
      incusGcDeps = [
        "incus-preseed.service"
        "incus-images.service"
      ];
    in
      {
        incus-machines-reconciler = lib.mkIf (cfg.reconcilePolicy != "off") {
          description = "Reconciler for declared Incus guests";
          wantedBy = lib.optional cfg.autoReconcile "multi-user.target";
          after = incusLifecycleDeps;
          wants = incusLifecycleDeps;
          serviceConfig = {
            Type = "oneshot";
            Environment = [
              (mkEnvAssignment "INCUS_MACHINES_RECONCILE_MODE" cfg.reconcilePolicy)
              (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
            ];
            ExecStart = "${helperScript} reconciler --all";
          };
        };

        incus-images = {
          description = "Import/update declared Incus images";
          wantedBy = ["sysinit-reactivation.target"];
          after = ["incus-preseed.service"];
          wants = ["incus-preseed.service"];
          restartTriggers = [
            helperScript
            incusSwitchStateFile
          ];
          restartIfChanged = true;
          serviceConfig = {
            Type = "oneshot";
            Environment = [
              (mkEnvAssignment "INCUS_MACHINES_IMAGE_TAG" cfg.imageTag)
              (mkEnvAssignment "INCUS_MACHINES_DECLARED_IMAGES" declaredImagesJson)
            ];
            ExecStart = "${helperScript} images";
          };
        };

        incus-machines-gc = {
          description = "Garbage-collect Incus containers no longer declared in NixOS config";
          wantedBy = ["sysinit-reactivation.target"];
          after = incusGcDeps;
          wants = incusGcDeps;
          restartTriggers = [
            helperScript
            incusSwitchStateFile
          ];
          restartIfChanged = true;
          serviceConfig = {
            Type = "oneshot";
            Environment = [
              (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
            ];
            ExecStart = "${helperScript} gc";
          };
        };
      }
      // lib.mapAttrs' mkMachineService cfg.instances;
  };
}
