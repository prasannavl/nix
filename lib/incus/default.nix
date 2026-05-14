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
  hasHostHooks = hasInstances || cfg.hostSuspend.enable;
  mkEnvAssignment = name: value: "${name}=${lib.escapeShellArg (toString value)}";
  remoteValue = value:
    if value == null
    then ""
    else value;
  remoteEnvExports = lib.optionalString cfg.remote.enable ''
    export INCUS_MACHINES_REMOTE_NAME=${lib.escapeShellArg cfg.remote.name}
    export INCUS_MACHINES_REMOTE_ADDRESS=${lib.escapeShellArg (remoteValue cfg.remote.address)}
    export INCUS_MACHINES_REMOTE_PROJECT=${lib.escapeShellArg cfg.remote.project}
    export INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE=${lib.escapeShellArg (remoteValue cfg.remote.clientCertificateFile)}
    export INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE=${lib.escapeShellArg (remoteValue cfg.remote.clientKeyFile)}
    export INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE=${lib.boolToString cfg.remote.acceptCertificate}
    ${lib.optionalString (cfg.remote.serverCertificateFile != null)
      "export INCUS_MACHINES_REMOTE_SERVER_CERT_FILE=${lib.escapeShellArg cfg.remote.serverCertificateFile}"}
  '';
  remoteServiceEnvironment = lib.optionals cfg.remote.enable ([
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_NAME" cfg.remote.name)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ADDRESS" (remoteValue cfg.remote.address))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_PROJECT" cfg.remote.project)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE" (remoteValue cfg.remote.clientCertificateFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE" (remoteValue cfg.remote.clientKeyFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE" (lib.boolToString cfg.remote.acceptCertificate))
    ]
    ++ lib.optional (cfg.remote.serverCertificateFile != null)
    (mkEnvAssignment "INCUS_MACHINES_REMOTE_SERVER_CERT_FILE" cfg.remote.serverCertificateFile));

  helperPackage = pkgs.writeShellApplication {
    name = "incus-machines-helper";
    excludeShellChecks = ["SC1091" "SC2016"];
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
      pkgs.openssl
      pkgs.systemd
    ];
    text = ''
      source ${./helper.sh}
      main "$@"
    '';
  };
  helperScript = "${helperPackage}/bin/incus-machines-helper";
  helperCommand = "/run/current-system/sw/bin/incus-machines-helper";

  reconcilerCommand = pkgs.writeShellScriptBin "incus-machines-reconciler" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_RECONCILE_MODE=${lib.escapeShellArg cfg.reconcilePolicy}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    exec ${helperScript} reconciler "$@"
  '';

  settlementCommand = pkgs.writeShellScriptBin "incus-machines-settlement" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_IPV4_ADDRESSES=${lib.escapeShellArg instanceIpv4AddressesJson}
    export INCUS_MACHINES_INSTANCE_SSH_PORTS=${lib.escapeShellArg instanceSshPortsJson}
    export INCUS_MACHINES_INSTANCE_WAIT_FOR_SSH=${lib.escapeShellArg instanceWaitForSshJson}
    exec ${helperScript} settlement "$@"
  '';

  hostSuspendCommand = pkgs.writeShellScriptBin "incus-machines-host-suspend" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_HOST_SUSPEND_STATE_DIR=${lib.escapeShellArg cfg.hostSuspend.stateDir}
    export INCUS_MACHINES_HOST_SUSPEND_DEFAULT_POLICY=${lib.escapeShellArg cfg.hostSuspend.defaultPolicy}
    export INCUS_MACHINES_HOST_SUSPEND_INCLUDE_VMS=${lib.boolToString cfg.hostSuspend.includeVirtualMachines}
    export INCUS_MACHINES_HOST_SUSPEND_GRACE_TIMEOUT=${toString cfg.hostSuspend.graceTimeoutSec}
    export INCUS_MACHINES_HOST_SUSPEND_FORCE_TIMEOUT=${toString cfg.hostSuspend.forceTimeoutSec}
    export INCUS_MACHINES_HOST_SUSPEND_RESTART=${lib.boolToString cfg.hostSuspend.restart}
    exec ${helperScript} host-suspend "$@"
  '';

  incusPreseed = config.virtualisation.incus.preseed;
  preseedCertificates =
    if incusPreseed == null
    then []
    else incusPreseed.certificates or [];
  hasIncusPreseed = incusPreseed != null;
  certificatesJson = builtins.toJSON cfg.certificates;
  certificatesFile = pkgs.writeText "incus-machines-certificates.json" certificatesJson;
  certificatesStateFile = "/var/lib/incus-machines/certificates.json";
  legacyCertificatesStateFile = "/var/lib/incus-machines/preseed-certificates.json";
  invalidRestrictedCertificates = map (cert: cert.name) (
    lib.filter (cert: cert.restricted && cert.projects == []) cfg.certificates
  );

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

  certificateType = lib.types.submodule (_: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Incus trust-store certificate name.";
      };

      type = lib.mkOption {
        type = lib.types.enum ["client" "metrics"];
        default = "client";
        description = "Incus trusted certificate type.";
      };

      restricted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to restrict the trusted certificate to selected projects.";
      };

      projects = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Projects this trusted certificate can access when restricted.";
      };

      certificate = lib.mkOption {
        type = lib.types.str;
        description = "PEM encoded public certificate material.";
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
      hostSuspendPolicy = lib.mkOption {
        type = lib.types.enum ["stop" "ignore"];
        default = "stop";
        description = ''
          Host sleep policy for this guest. `stop` lets the parent host stop the
          guest before suspend so guest userspace cannot block the host freezer;
          `ignore` opts out for guests with a separately justified lifecycle.
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

  machineRuntimeStateJson = name: machine: let
    instanceImage = instanceImages.${name};
    hash = configHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
    createOnlyDevSpec = createOnlyDeviceSpecJson machine;
    userMetaJson = builtins.toJSON (mkUserMetadata name machine);
    configJson = builtins.toJSON machine.config;
  in
    builtins.toJSON {
      name = name;
      imageTag = cfg.imageTag;
      instanceImage = instanceImage;
      createRef = instanceImage.createRef;
      ipv4Address = machine.ipv4Address;
      configHash = hash;
      bootTag = machine.bootTag;
      recreateTag = machine.recreateTag;
      removalPolicy = machine.removalPolicy;
      desiredDisks = builtins.fromJSON diskDevSpec;
      desiredDiskGcMetadata = builtins.fromJSON diskGcMetadata;
      createOnlyDevices = builtins.fromJSON createOnlyDevSpec;
      userMeta = builtins.fromJSON userMetaJson;
      config = builtins.fromJSON configJson;
    };

  machineLifecycleStateJson = name: machine: let
    hash = configHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
  in
    builtins.toJSON {
      configHash = hash;
      ipv4Address = machine.ipv4Address;
      bootTag = machine.bootTag;
      recreateTag = machine.recreateTag;
      removalPolicy = machine.removalPolicy;
      desiredDisks = diskDevSpec;
      desiredDiskGcMetadata = diskGcMetadata;
    };

  mkUserMetadata = name: machine:
    {
      "user.managed-by" = "nixos";
      "user.config-hash" = configHash name machine;
      "user.boot-tag" = machine.bootTag;
      "user.recreate-tag" = machine.recreateTag;
      "user.removal-policy" = machine.removalPolicy;
      "user.host-suspend.policy" = machine.hostSuspendPolicy;
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

  pow2 = exponent:
    if exponent == 0
    then 1
    else 2 * pow2 (exponent - 1);

  parseIpv4 = value: let
    parts = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)" value;
  in
    if parts == null
    then throw "Invalid IPv4 address for services.incusMachines: ${value}"
    else let
      octets = map lib.toInt parts;
    in
      if !lib.all (octet: octet >= 0 && octet <= 255) octets
      then throw "Invalid IPv4 address for services.incusMachines: ${value}"
      else octets;

  ipv4ToInt = value: let
    octets = parseIpv4 value;
  in
    (builtins.elemAt octets 0)
    * 16777216
    + (builtins.elemAt octets 1) * 65536
    + (builtins.elemAt octets 2) * 256
    + (builtins.elemAt octets 3);

  parseCidr = subnet: let
    parts = lib.splitString "/" subnet;
  in
    if builtins.length parts != 2
    then throw "Invalid IPv4 CIDR for services.incusMachines.remote.allowedSubnets: ${subnet}"
    else let
      prefixLength = lib.toInt (builtins.elemAt parts 1);
      size = pow2 (32 - prefixLength);
      base = ipv4ToInt (builtins.elemAt parts 0);
    in
      if prefixLength < 0 || prefixLength > 32
      then throw "Invalid IPv4 CIDR for services.incusMachines.remote.allowedSubnets: ${subnet}"
      else {
        start = (builtins.div base size) * size;
        end = ((builtins.div base size) + 1) * size - 1;
      };

  ipv4InCidr = value: subnet: let
    address = ipv4ToInt value;
    cidr = parseCidr subnet;
  in
    address >= cidr.start && address <= cidr.end;

  instancesOutsideAllowedSubnets =
    lib.filter (
      name:
        !lib.any
        (subnet: ipv4InCidr cfg.instances.${name}.ipv4Address subnet)
        cfg.remote.allowedSubnets
    )
    (builtins.attrNames cfg.instances);

  allowedSubnetViolations =
    map (name: "${name} (${cfg.instances.${name}.ipv4Address})") instancesOutsideAllowedSubnets;

  declaredImagesJson = builtins.toJSON declaredImages;
  declaredInstancesJson = builtins.toJSON (builtins.attrNames cfg.instances);
  instanceIpv4AddressesJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.ipv4Address) cfg.instances);
  instanceSshPortsJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.sshPort) cfg.instances);
  instanceWaitForSshJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.waitForSsh) cfg.instances);
  incusImagesStateFile = pkgs.writeText "incus-machines-images-state.json" (builtins.toJSON {
    imageTag = cfg.imageTag;
    images = declaredImages;
  });
  incusGcStateFile = pkgs.writeText "incus-machines-gc-state.json" (builtins.toJSON {
    instances = builtins.attrNames cfg.instances;
  });
  localIncusDeps = lib.optional (!cfg.remote.enable) "incus-preseed.service";
  incusLifecycleDeps =
    localIncusDeps
    ++ [
      "network-online.target"
      "incus-images.service"
    ];

  mkMachineService = name: machine: let
    lifecycleStateFile = pkgs.writeText "incus-machine-${name}-lifecycle-state.json" (machineLifecycleStateJson name machine);
  in
    lib.nameValuePair "incus-${name}" {
      description = "Incus container lifecycle for ${name}";
      wantedBy = ["multi-user.target"];
      after = incusLifecycleDeps;
      wants = incusLifecycleDeps;
      requires = localIncusDeps ++ ["incus-images.service"];
      restartTriggers = [lifecycleStateFile];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment =
          [
            (mkEnvAssignment "INCUS_MACHINES_INSTANCE_STATE_FILE" "/etc/incus-machines/${name}.json")
          ]
          ++ remoteServiceEnvironment;
        ExecStop = "-${helperCommand} stop-instance ${lib.escapeShellArg name}";
        ExecStart = "${helperCommand} machine";
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

    certificates = lib.mkOption {
      type = lib.types.listOf certificateType;
      default = [];
      description = ''
        Declarative Incus trusted certificates reconciled by this module. The
        upstream Incus preseed remains responsible for fabric objects such as
        projects, networks, profiles, and storage pools.
      '';
    };

    remote = {
      enable = lib.mkEnableOption ''
        managing a remote Incus daemon instead of the local host daemon
      '';

      name = lib.mkOption {
        type = lib.types.str;
        default = "local";
        description = "Incus client remote name used by helper commands.";
      };

      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote Incus HTTPS API address.";
      };

      project = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Default Incus project for the remote client.";
      };

      clientCertificateFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        description = "Path to the public client certificate used for remote TLS auth.";
      };

      clientKeyFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        description = "Path to the private client key used for remote TLS auth.";
      };

      serverCertificateFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        description = "Optional pinned remote Incus server certificate.";
      };

      acceptCertificate = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether helpers may accept the server certificate when creating the
          ephemeral Incus client config. Prefer `serverCertificateFile` when a
          stable server certificate is available.
        '';
      };

      allowedSubnets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["10.10.20.0/24"];
        description = ''
          Optional IPv4 CIDR allowlist for declared instance addresses managed
          through this remote. When non-empty, every
          `services.incusMachines.instances.<name>.ipv4Address` must fall
          inside at least one listed subnet.
        '';
      };
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

    hostSuspend = {
      enable = lib.mkEnableOption ''
        stopping running Incus containers before host sleep so container tasks
        cannot block the physical host suspend freezer
      '';

      defaultPolicy = lib.mkOption {
        type = lib.types.enum ["stop" "ignore"];
        default = "stop";
        description = ''
          Policy for running containers that do not set
          `user.host-suspend.policy`. `stop` is the laptop-safe default; set an
          instance config key to `ignore` for explicit opt-outs.
        '';
      };

      includeVirtualMachines = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to include Incus virtual machines in the host sleep stop/start cycle.";
      };

      graceTimeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Seconds to wait for a graceful Incus stop before forcing the instance off.";
      };

      forceTimeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds to allow a forced Incus stop command before treating it as failed.";
      };

      restart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Restart instances that were stopped by the pre-sleep hook after resume.";
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/run/incus-machines-host-suspend";
        description = "Runtime directory used to remember which instances were stopped before sleep.";
      };
    };
  };

  config = lib.mkIf hasHostHooks {
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
      {
        assertion = preseedCertificates == [];
        message = "Use services.incusMachines.certificates instead of virtualisation.incus.preseed.certificates.";
      }
      {
        assertion = invalidRestrictedCertificates == [];
        message =
          "services.incusMachines.certificates restricted certificates must declare at least one project: "
          + lib.concatStringsSep ", " invalidRestrictedCertificates;
      }
      {
        assertion = !cfg.remote.enable || cfg.remote.name != "local";
        message = "services.incusMachines.remote.name must not be 'local' when remote mode is enabled.";
      }
      {
        assertion = !cfg.remote.enable || cfg.remote.address != null;
        message = "services.incusMachines.remote.address is required when remote mode is enabled.";
      }
      {
        assertion = !cfg.remote.enable || cfg.remote.clientCertificateFile != null;
        message = "services.incusMachines.remote.clientCertificateFile is required when remote mode is enabled.";
      }
      {
        assertion = !cfg.remote.enable || cfg.remote.clientKeyFile != null;
        message = "services.incusMachines.remote.clientKeyFile is required when remote mode is enabled.";
      }
      {
        assertion = !cfg.remote.enable || cfg.remote.serverCertificateFile != null || cfg.remote.acceptCertificate;
        message = "services.incusMachines.remote must set serverCertificateFile or acceptCertificate = true.";
      }
      {
        assertion = !cfg.remote.enable || !cfg.hostSuspend.enable;
        message = "services.incusMachines.hostSuspend is only supported for local Incus management.";
      }
      {
        assertion = cfg.remote.allowedSubnets == [] || instancesOutsideAllowedSubnets == [];
        message =
          "services.incusMachines instances outside remote.allowedSubnets ("
          + lib.concatStringsSep ", " cfg.remote.allowedSubnets
          + "): "
          + lib.concatStringsSep ", " allowedSubnetViolations;
      }
    ];

    virtualisation.incus = {
      enable = lib.mkDefault (!cfg.remote.enable);
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault (!cfg.remote.enable);
    };

    systemd.tmpfiles.rules = lib.mkIf (!cfg.remote.enable) (
      lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles cfg.instances)
    );

    environment.systemPackages = [
      helperPackage
      reconcilerCommand
      settlementCommand
      hostSuspendCommand
    ];

    powerManagement = lib.mkIf cfg.hostSuspend.enable {
      powerDownCommands = ''
        ${hostSuspendCommand}/bin/incus-machines-host-suspend pre
      '';
      resumeCommands = ''
        ${hostSuspendCommand}/bin/incus-machines-host-suspend post
      '';
    };

    environment.etc = lib.mkIf hasInstances (
      lib.mapAttrs'
      (name: machine:
        lib.nameValuePair "incus-machines/${name}.json" {
          text = machineRuntimeStateJson name machine;
        })
      cfg.instances
    );

    systemd.services =
      {
        incus-machines-certificates = lib.mkIf (!cfg.remote.enable) {
          description = "Reconcile declared Incus trusted certificates";
          wantedBy = ["sysinit-reactivation.target"];
          after = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
          wants = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
          restartTriggers = [
            helperScript
            certificatesFile
          ];
          restartIfChanged = true;
          serviceConfig.Environment = [
            (mkEnvAssignment "INCUS_MACHINES_CERTIFICATES_FILE" certificatesFile)
            (mkEnvAssignment "INCUS_MACHINES_CERTIFICATES_STATE_FILE" certificatesStateFile)
            (mkEnvAssignment "INCUS_MACHINES_LEGACY_CERTIFICATES_STATE_FILE" legacyCertificatesStateFile)
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            ${helperScript} certificates
          '';
        };
      }
      // lib.optionalAttrs hasInstances (let
        incusGcDeps = localIncusDeps ++ ["incus-images.service"];
        incusImagesDeps = localIncusDeps ++ ["network-online.target"];
      in
        {
          incus-machines-reconciler = lib.mkIf (cfg.reconcilePolicy != "off") {
            description = "Reconciler for declared Incus guests";
            wantedBy = lib.optional cfg.autoReconcile "multi-user.target";
            after = incusLifecycleDeps;
            wants = incusLifecycleDeps;
            serviceConfig = {
              Type = "oneshot";
              Environment =
                [
                  (mkEnvAssignment "INCUS_MACHINES_RECONCILE_MODE" cfg.reconcilePolicy)
                  (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
                ]
                ++ remoteServiceEnvironment;
              ExecStart = "${helperScript} reconciler --all";
            };
          };

          incus-images = {
            description = "Import/update declared Incus images";
            wantedBy = ["sysinit-reactivation.target"];
            after = incusImagesDeps;
            wants = incusImagesDeps;
            restartTriggers = [
              helperScript
              incusImagesStateFile
            ];
            restartIfChanged = true;
            serviceConfig = {
              Type = "oneshot";
              Environment =
                [
                  (mkEnvAssignment "INCUS_MACHINES_IMAGE_TAG" cfg.imageTag)
                  (mkEnvAssignment "INCUS_MACHINES_DECLARED_IMAGES" declaredImagesJson)
                ]
                ++ remoteServiceEnvironment;
              ExecStart = "${helperScript} images";
            };
          };

          incus-machines-gc = {
            description = "Garbage-collect Incus containers no longer declared in NixOS config";
            enable = !cfg.remote.enable;
            wantedBy = ["sysinit-reactivation.target"];
            after = incusGcDeps;
            wants = incusGcDeps;
            restartTriggers = [
              helperScript
              incusGcStateFile
            ];
            restartIfChanged = true;
            serviceConfig = {
              Type = "oneshot";
              Environment =
                [
                  (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
                ]
                ++ remoteServiceEnvironment;
              ExecStart = "${helperScript} gc";
            };
          };
        }
        // lib.mapAttrs' mkMachineService cfg.instances);
  };
}
