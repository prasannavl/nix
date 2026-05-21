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

  incusMachinesStateDir = "/var/lib/incus-machines";
  managedGcDirRoot = "${incusMachinesStateDir}/managed-dirs";
  certificateDelegationsRoot = "/var/lib/incus-delegations";
  certificateDelegationGuestRoot = "/var/lib/incus-delegation";
  certificateDelegationStateDir = "${incusMachinesStateDir}/delegated-certificates";

  certificatesStateFile = "${incusMachinesStateDir}/certificates.json";
  legacyCertificatesStateFile = "${incusMachinesStateDir}/preseed-certificates.json";
  certificateDelegationsStateFile = "${certificateDelegationStateDir}/delegations.json";

  hasInstances = cfg.instances != {};
  hasCertificates = cfg.certificates != [];
  hasCertificateDelegations = cfg.certificateDelegations != {};
  hasHostHooks = hasInstances || hasCertificates || hasCertificateDelegations || cfg.hostSuspend.enable;
  mkEnvAssignment = name: value: "${name}=${lib.escapeShellArg (toString value)}";
  remoteValue = value:
    if value == null
    then ""
    else value;
  materializeRemoteFile = value:
    if value == null
    then null
    else if builtins.isPath value
    then pkgs.writeText (builtins.baseNameOf value) (builtins.readFile value)
    else value;
  remoteClientCertificateFile = materializeRemoteFile cfg.remote.clientCertificateFile;
  remoteServerCertificateFile = materializeRemoteFile cfg.remote.serverCertificateFile;
  remoteEnvExports = lib.optionalString cfg.remote.enable ''
    export INCUS_MACHINES_REMOTE_NAME=${lib.escapeShellArg cfg.remote.name}
    export INCUS_MACHINES_REMOTE_ADDRESS=${lib.escapeShellArg (remoteValue cfg.remote.address)}
    export INCUS_MACHINES_REMOTE_PROJECT=${lib.escapeShellArg cfg.remote.project}
    export INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE=${lib.escapeShellArg (remoteValue remoteClientCertificateFile)}
    export INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE=${lib.escapeShellArg (remoteValue cfg.remote.clientKeyFile)}
    export INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE=${lib.boolToString cfg.remote.acceptCertificate}
    ${lib.optionalString (cfg.remote.serverCertificateFile != null)
      "export INCUS_MACHINES_REMOTE_SERVER_CERT_FILE=${lib.escapeShellArg remoteServerCertificateFile}"}
  '';
  remoteServiceEnvironment = lib.optionals cfg.remote.enable ([
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_NAME" cfg.remote.name)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ADDRESS" (remoteValue cfg.remote.address))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_PROJECT" cfg.remote.project)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE" (remoteValue remoteClientCertificateFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE" (remoteValue cfg.remote.clientKeyFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE" (lib.boolToString cfg.remote.acceptCertificate))
    ]
    ++ lib.optional (cfg.remote.serverCertificateFile != null)
    (mkEnvAssignment "INCUS_MACHINES_REMOTE_SERVER_CERT_FILE" remoteServerCertificateFile));
  remoteCertificateDelegationName =
    if cfg.remote.certificateDelegation.name != null
    then cfg.remote.certificateDelegation.name
    else cfg.remote.project;
  remoteCertificateDelegationDirectory =
    if cfg.remote.certificateDelegation.directory != null
    then cfg.remote.certificateDelegation.directory
    else "${certificateDelegationGuestRoot}/${remoteCertificateDelegationName}";
  remoteProjectDelegationUnit = "incus-remote-project-delegated-certificates.service";
  remoteProjectDelegationDeps = lib.optional hasRemoteProjectDelegations remoteProjectDelegationUnit;
  certificateDelegationsRootEnv =
    mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATIONS_ROOT" certificateDelegationsRoot;

  helperPackage = pkgs.writeShellApplication {
    name = "incus-machines-helper";
    excludeShellChecks = ["SC1091" "SC2016"];
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
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
  # Switch-time units must pair new state JSON with the same generation's
  # helper; /run/current-system can still point at the old generation here.
  helperScript = "${helperPackage}/bin/incus-machines-helper";

  reconcilerCommand = pkgs.writeShellScriptBin "incus-machines-reconciler" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_RECONCILE_MODE=${lib.escapeShellArg cfg.reconcilePolicy}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_PROJECTS=${lib.escapeShellArg instanceProjectsJson}
    exec ${helperScript} reconciler "$@"
  '';

  settlementCommand = pkgs.writeShellScriptBin "incus-machines-settlement" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_PROJECTS=${lib.escapeShellArg instanceProjectsJson}
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
  preseedProjectNames =
    if incusPreseed == null
    then []
    else map (project: project.name) (incusPreseed.projects or []);
  preseedMigrationHasAction = migration:
    migration.unsetInstanceConfigKeyPrefixes
    != []
    || migration.ensureStoragePools != []
    || migration.moveInstancesToStoragePools != []
    || migration.moveStorageVolumes != []
    || migration.setProjectConfig != []
    || migration.setProfileDeviceProperties != [];
  resolvedPreseedMigrations =
    lib.filter
    (migration: migration.projects != [] && preseedMigrationHasAction migration)
    (map (migration: {
        projects =
          if migration.projects == null
          then preseedProjectNames
          else migration.projects;
        inherit (migration) ensureStoragePools moveInstancesToStoragePools moveStorageVolumes setProfileDeviceProperties setProjectConfig unsetInstanceConfigKeyPrefixes;
      })
      cfg.preseedMigrations);
  hasPreseedMigrations = !cfg.remote.enable && hasIncusPreseed && resolvedPreseedMigrations != [];
  preseedMigrationsFile = pkgs.writeText "incus-machines-preseed-migrations.json" (builtins.toJSON resolvedPreseedMigrations);
  certificatesJson = builtins.toJSON cfg.certificates;
  certificatesFile = pkgs.writeText "incus-machines-certificates.json" certificatesJson;
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

  stripSuffixes = suffixes: value:
    lib.foldl'
    (acc: suffix:
      if lib.hasSuffix suffix acc
      then lib.removeSuffix suffix acc
      else acc)
    value
    suffixes;

  remoteProjectCertName = projectName: cert: let
    base = builtins.baseNameOf (toString cert.file);
    withoutExtension = stripSuffixes [".age" ".crt" ".pem" ".cert"] base;
    projectSuffix = "-${projectName}";
  in
    if cert.name != null
    then cert.name
    else if lib.hasSuffix projectSuffix withoutExtension
    then lib.removeSuffix projectSuffix withoutExtension
    else withoutExtension;

  legacyRemoteProject = lib.optionalAttrs (cfg.remote.allowedSubnets != [] || cfg.remote.certificateDelegation.enable) {
    ${cfg.remote.project} = {
      allowedSubnets = cfg.remote.allowedSubnets;
      certs = [];
      includeClientCertificate = cfg.remote.certificateDelegation.enable;
      certificateName = cfg.remote.certificateDelegation.certificateName;
      directory = remoteCertificateDelegationDirectory;
      fileName = cfg.remote.certificateDelegation.fileName;
      waitForTrust = cfg.remote.certificateDelegation.waitForTrust;
      waitTimeoutSeconds = cfg.remote.certificateDelegation.waitTimeoutSeconds;
    };
  };

  effectiveRemoteProjects =
    if cfg.remote.projects != {}
    then cfg.remote.projects
    else legacyRemoteProject;

  remoteProjectCertificates = projectName: project:
    lib.optional project.includeClientCertificate {
      name = project.certificateName;
      file = remoteClientCertificateFile;
      automatic = true;
    }
    ++ map (cert: {
      name = remoteProjectCertName projectName cert;
      file = materializeRemoteFile cert.file;
      automatic = false;
    })
    project.certs;

  remoteProjectDelegations =
    lib.mapAttrs (
      projectName: project: {
        inherit (project) directory fileName waitForTrust waitTimeoutSeconds;
        certificates = map (cert: {
          inherit (cert) name automatic;
          file = toString cert.file;
        }) (remoteProjectCertificates projectName project);
      }
    )
    effectiveRemoteProjects;

  hasRemoteProjectDelegations = cfg.remote.enable && effectiveRemoteProjects != {};
  remoteProjectDelegationsFile = pkgs.writeText "incus-remote-project-delegated-certificates.json" (builtins.toJSON remoteProjectDelegations);

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
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Storage pool for volume-backed disk devices. When unset, the pool
          defaults to the resolved Incus project for the instance.
        '';
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

      certDelegation = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of a parent-side certificate delegation to mount into this
          instance. The named `services.incusMachines.certificateDelegations`
          entry owns the host directory and project binding.
        '';
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

  certificateDelegationType = lib.types.submodule ({name, ...}: {
    options = {
      project = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Incus project that delegated certificates are restricted to.";
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "${certificateDelegationsRoot}/${name}";
        description = "Host directory containing the tenant-owned delegated certificate state file.";
      };

      guestPath = lib.mkOption {
        type = lib.types.str;
        default = "${certificateDelegationGuestRoot}/${name}";
        description = "Guest mount path for the delegated certificate directory.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "certs.json";
        description = "Tenant-owned JSON file name under the delegation directory.";
      };

      stateFile = lib.mkOption {
        type = lib.types.str;
        default = "${certificateDelegationStateDir}/${name}.json";
        description = "Parent-owned state file tracking certificates managed by this delegation.";
      };

      namePrefix = lib.mkOption {
        type = lib.types.str;
        default = "${name}-delegated-";
        description = "Prefix forced onto trusted certificate names created from this delegation.";
      };

      maxCertificates = lib.mkOption {
        type = lib.types.ints.positive;
        default = 32;
        description = "Maximum number of delegated certificates accepted from the tenant state file.";
      };
    };
  });

  remoteProjectCertFileType = lib.types.either lib.types.path lib.types.str;

  remoteProjectCertType = projectName:
    lib.types.coercedTo
    remoteProjectCertFileType
    (file: {file = file;})
    (lib.types.submodule (_: {
      options = {
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Tenant-local certificate name. When unset, the name is derived from
            the certificate file basename, stripping the delegated project
            suffix when present.
          '';
        };

        file = lib.mkOption {
          type = remoteProjectCertFileType;
          description = ''
            Runtime-readable PEM certificate file to publish into the delegated
            certificate state for project `${projectName}`.
          '';
        };
      };
    }));

  remoteProjectType = lib.types.submodule ({name, ...}: {
    options = {
      allowedSubnets = lib.mkOption {
        type = lib.types.coercedTo lib.types.str (value: [value]) (lib.types.listOf lib.types.str);
        default = [];
        example = ["10.10.100.0/24"];
        description = ''
          Optional IPv4 CIDR allowlist for instances declared in this remote
          project. When non-empty, each instance assigned to this project must
          use an address inside one of these subnets.
        '';
      };

      certs = lib.mkOption {
        type = lib.types.listOf (remoteProjectCertType name);
        default = [];
        description = ''
          Additional PEM certificates to publish into this project's delegated
          certificate state file. Bare path and string entries derive their
          tenant-local name from the file basename; use `{ name, file }` when a
          specific name is required.
        '';
      };

      includeClientCertificate = lib.mkOption {
        type = lib.types.bool;
        default = name == cfg.remote.project;
        description = ''
          Whether to include this remote client's certificate in this project's
          delegated certificate state. Defaults to true only for
          `services.incusMachines.remote.project`.
        '';
      };

      certificateName = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        description = ''
          Tenant-local name used when `includeClientCertificate` publishes this
          remote client's certificate.
        '';
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "${certificateDelegationGuestRoot}/${name}";
        description = "Guest-visible delegated certificate directory for this project.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "certs.json";
        description = "Delegated certificate JSON file written under `directory`.";
      };

      waitForTrust = lib.mkOption {
        type = lib.types.bool;
        default = name == cfg.remote.project;
        description = ''
          Wait for the remote Incus API to accept this client's certificate
          after writing delegated certificate state.
        '';
      };

      waitTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Seconds to wait for parent trust reconciliation.";
      };
    };
  });

  preseedMigrationType = lib.types.submodule (_: {
    options = {
      projects = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Incus projects to migrate before `incus-preseed.service` runs.
          `null` means all projects declared by
          `virtualisation.incus.preseed.projects`.
        '';
      };

      ensureStoragePools = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus storage pool name to create or align.";
            };

            driver = lib.mkOption {
              type = lib.types.str;
              description = "Incus storage pool driver.";
            };

            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Incus storage pool description.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Incus storage pool config keys.";
            };
          };
        }));
        default = [];
        description = "Storage pools to create or align before preseed applies project restrictions.";
      };

      setProfileDeviceProperties = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the profile.";
            };

            profile = lib.mkOption {
              type = lib.types.str;
              description = "Incus profile name.";
            };

            device = lib.mkOption {
              type = lib.types.str;
              description = "Incus profile device name.";
            };

            properties = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Device properties to set before preseed applies project restrictions.";
            };
          };
        }));
        default = [];
        description = "Existing profile device properties to align before project restriction updates.";
      };

      setProjectConfig = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project to update.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Project config keys to set before other preseed migrations.";
            };
          };
        }));
        default = [];
        description = "Project config keys to set before profile, volume, or restriction updates.";
      };

      moveInstancesToStoragePools = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the instance.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name.";
            };

            pool = lib.mkOption {
              type = lib.types.str;
              description = "Destination storage pool for the instance root volume.";
            };
          };
        }));
        default = [];
        description = "Instances to move to another storage pool before profile or project restriction updates.";
      };

      moveStorageVolumes = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the custom storage volume.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Custom storage volume name.";
            };

            fromPool = lib.mkOption {
              type = lib.types.str;
              description = "Source storage pool.";
            };

            toPool = lib.mkOption {
              type = lib.types.str;
              description = "Destination storage pool.";
            };
          };
        }));
        default = [];
        description = "Custom storage volumes to move before disk-device pool changes.";
      };

      unsetInstanceConfigKeyPrefixes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Instance config key prefixes to remove before preseed. This is for
          stale keys that would make a later project restriction update fail.
        '';
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
      project = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Incus project for this instance. Defaults to the configured remote
          project in remote mode and `default` for local Incus management.
        '';
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
      adopt = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Adopt an existing Incus instance with the same name instead of
          refusing to manage it when it lacks this module's ownership metadata.
          Adoption applies declared config and module-owned `user.*` metadata,
          including host-suspend policy. The first adoption pass does not remove
          undeclared disk devices; later reconciles enforce the declared disk set.
        '';
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

  resolveCertDelegationDevice = dev:
    if dev.certDelegation == null
    then dev
    else let
      delegation = cfg.certificateDelegations.${dev.certDelegation};
    in
      dev
      // {
        source = delegation.directory;
        path = delegation.guestPath;
      };

  isHostPath = source: source != null && lib.hasPrefix "/" source;
  isHostPathDiskResolved = dev:
    dev.type == "disk" && isHostPath dev.source;
  isManagedHostDirResolved = dev:
    isHostPathDiskResolved dev && !lib.hasPrefix "/dev/" dev.source;
  isVolumeBackedDiskResolved = dev:
    dev.type == "disk" && dev.source != null && !isHostPath dev.source;

  resolveDeviceProperties = machine: _name: dev: let
    resolved = resolveCertDelegationDevice dev;
    pool =
      if resolved.pool != null
      then resolved.pool
      else resolveMachineProject machine;
    base = {inherit (resolved) type;};
    withSource = lib.optionalAttrs (resolved.source != null) {inherit (resolved) source;};
    withPath = lib.optionalAttrs (resolved.path != null) {inherit (resolved) path;};
    withShift = lib.optionalAttrs (resolved.type == "disk" && resolved.shift) {shift = "true";};
    withPool = lib.optionalAttrs (isVolumeBackedDiskResolved resolved) {pool = pool;};
  in
    base // withSource // withPath // withShift // withPool // resolved.extraProperties;

  resolveMachineProject = machine:
    if machine.project != null
    then machine.project
    else if cfg.remote.enable
    then cfg.remote.project
    else "default";

  createOnlyDevices = machine:
    lib.filterAttrs (_: dev: dev.type != "disk") machine.devices;
  syncableDevices = machine:
    lib.filterAttrs (_: dev: dev.type == "disk") machine.devices;

  configHashPayload = name: machine: {
    preseedTag = cfg.preseedTag;
    inherit (machine) config;
    project = resolveMachineProject machine;
    image = let
      resolvedImage = resolveMachineImage name machine;
    in {
      inherit (resolvedImage) alias;
    };
    createOnlyDevices = lib.mapAttrs (resolveDeviceProperties machine) (createOnlyDevices machine);
  };

  # Transitional compatibility for generations that hashed the derived
  # `local:<alias>` createRef. Remove after all active Incus parents have
  # reconciled once with `acceptedConfigHashes` in their runtime state.
  # TODO(2026-07-01): remove this legacy hash payload after deployed parents
  # have had enough time to pass through one reconcile.
  legacyConfigHashPayload = name: machine:
    configHashPayload name machine
    // {
      image = let
        resolvedImage = resolveMachineImage name machine;
      in {
        inherit (resolvedImage) alias;
        createRef = "local:${resolvedImage.alias}";
      };
    };

  configHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON (configHashPayload name machine));

  acceptedConfigHashes = name: machine: let
    current = configHash name machine;
    legacy = builtins.hashString "sha256" (builtins.toJSON (legacyConfigHashPayload name machine));
  in
    if current == legacy
    then [current]
    else [current legacy];

  lifecycleConfigHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON {
      configHash = configHash name machine;
      acceptedConfigHashes = acceptedConfigHashes name machine;
    });

  diskDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs (resolveDeviceProperties machine) (syncableDevices machine));

  diskGcMetadataJson = machine:
    builtins.toJSON (
      lib.mapAttrs
      (_: dev: let
        resolved = resolveCertDelegationDevice dev;
      in
        {
          inherit (resolved) removalPolicy;
        }
        // lib.optionalAttrs (resolved.certDelegation != null) {
          certificateDelegation = true;
          fileName = cfg.certificateDelegations.${resolved.certDelegation}.fileName;
        }
        // lib.optionalAttrs (isManagedHostDirResolved resolved) {inherit (resolved) source;})
      (syncableDevices machine)
    );

  createOnlyDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs (resolveDeviceProperties machine) (createOnlyDevices machine));

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
      imageAlias = instanceImage.alias;
      project = resolveMachineProject machine;
      ipv4Address = machine.ipv4Address;
      configHash = hash;
      acceptedConfigHashes = acceptedConfigHashes name machine;
      bootTag = machine.bootTag;
      recreateTag = machine.recreateTag;
      removalPolicy = machine.removalPolicy;
      adopt = machine.adopt;
      desiredDisks = builtins.fromJSON diskDevSpec;
      desiredDiskGcMetadata = builtins.fromJSON diskGcMetadata;
      createOnlyDevices = builtins.fromJSON createOnlyDevSpec;
      userMeta = builtins.fromJSON userMetaJson;
      config = builtins.fromJSON configJson;
    };

  machineLifecycleStateJson = name: machine: let
    hash = lifecycleConfigHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
  in
    builtins.toJSON {
      configHash = hash;
      project = resolveMachineProject machine;
      ipv4Address = machine.ipv4Address;
      bootTag = machine.bootTag;
      recreateTag = machine.recreateTag;
      removalPolicy = machine.removalPolicy;
      adopt = machine.adopt;
      desiredDisks = builtins.fromJSON diskDevSpec;
      desiredDiskGcMetadata = builtins.fromJSON diskGcMetadata;
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
      devName: dev: let
        resolved = resolveCertDelegationDevice dev;
      in
        lib.optionalAttrs (resolved.type == "disk") {
          "user.device.${devName}.removal-policy" = resolved.removalPolicy;
        }
        // lib.optionalAttrs (isManagedHostDirResolved resolved) {
          "user.device.${devName}.source" = resolved.source;
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
    then throw "Invalid IPv4 CIDR for services.incusMachines.remote project allowedSubnets: ${subnet}"
    else let
      prefixLength = lib.toInt (builtins.elemAt parts 1);
      size = pow2 (32 - prefixLength);
      base = ipv4ToInt (builtins.elemAt parts 0);
    in
      if prefixLength < 0 || prefixLength > 32
      then throw "Invalid IPv4 CIDR for services.incusMachines.remote project allowedSubnets: ${subnet}"
      else {
        start = (builtins.div base size) * size;
        end = ((builtins.div base size) + 1) * size - 1;
      };

  ipv4InCidr = value: subnet: let
    address = ipv4ToInt value;
    cidr = parseCidr subnet;
  in
    address >= cidr.start && address <= cidr.end;

  remoteProjectSubnets = project:
    if builtins.hasAttr project effectiveRemoteProjects
    then effectiveRemoteProjects.${project}.allowedSubnets
    else [];

  instancesWithoutRemoteProjectConfig =
    lib.filter (
      name:
        cfg.remote.enable
        && cfg.remote.projects != {}
        && !builtins.hasAttr (resolveMachineProject cfg.instances.${name}) cfg.remote.projects
    )
    (builtins.attrNames cfg.instances);

  instancesOutsideAllowedSubnets =
    lib.filter (
      name: let
        project = resolveMachineProject cfg.instances.${name};
        subnets = remoteProjectSubnets project;
      in
        subnets
        != []
        && !lib.any
        (subnet: ipv4InCidr cfg.instances.${name}.ipv4Address subnet)
        subnets
    )
    (builtins.attrNames cfg.instances);

  allowedSubnetViolations =
    map (
      name: let
        project = resolveMachineProject cfg.instances.${name};
      in "${name} (${project}, ${cfg.instances.${name}.ipv4Address})"
    )
    instancesOutsideAllowedSubnets;

  invalidCertificateDelegationNames =
    lib.filter
    (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
    (builtins.attrNames cfg.certificateDelegations);

  invalidRemoteProjectNames =
    lib.filter
    (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
    (builtins.attrNames cfg.remote.projects);

  invalidRemoteProjectCertificateNames = lib.concatLists (
    lib.mapAttrsToList (
      projectName: project:
        lib.filter
        (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
        (map (cert: cert.name) (remoteProjectCertificates projectName project))
    )
    effectiveRemoteProjects
  );

  remoteProjectCertificateFiles = lib.concatLists (
    lib.mapAttrsToList (
      projectName: project:
        map (cert: toString cert.file) (remoteProjectCertificates projectName project)
    )
    effectiveRemoteProjects
  );

  duplicateRemoteProjectCertificateFiles =
    lib.filter
    (file: builtins.length (lib.filter (candidate: candidate == file) remoteProjectCertificateFiles) > 1)
    (lib.unique remoteProjectCertificateFiles);

  invalidInstanceNames =
    lib.filter
    (name: builtins.match "[a-z]([a-z0-9-]{0,61}[a-z0-9])?" name == null)
    (builtins.attrNames cfg.instances);

  invalidRemoteCertificateDelegationName =
    cfg.remote.enable
    && cfg.remote.certificateDelegation.enable
    && builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" remoteCertificateDelegationName == null;

  invalidCertificateDelegationReferences = lib.concatLists (
    lib.mapAttrsToList (
      machineName: machine:
        lib.concatLists (
          lib.mapAttrsToList (
            deviceName: dev:
              lib.optional
              (dev.certDelegation != null && !builtins.hasAttr dev.certDelegation cfg.certificateDelegations)
              "${machineName}.${deviceName} -> ${dev.certDelegation}"
          )
          machine.devices
        )
    )
    cfg.instances
  );

  invalidCertificateDelegationDevices = lib.concatLists (
    lib.mapAttrsToList (
      machineName: machine:
        lib.concatLists (
          lib.mapAttrsToList (
            deviceName: dev:
              lib.optional
              (dev.certDelegation != null && dev.type != "disk")
              "${machineName}.${deviceName}"
          )
          machine.devices
        )
    )
    cfg.instances
  );

  hasParentPathSegment = source:
    builtins.elem ".." (lib.splitString "/" source);
  isManagedGcDir = source:
    !hasParentPathSegment source && source != managedGcDirRoot && lib.hasPrefix "${managedGcDirRoot}/" source;

  unsafeDeleteHostDirs = lib.concatLists (
    lib.mapAttrsToList (
      machineName: machine:
        lib.concatLists (
          lib.mapAttrsToList (
            deviceName: dev: let
              resolved = resolveCertDelegationDevice dev;
            in
              lib.optional
              (
                isManagedHostDirResolved resolved
                && resolved.removalPolicy == "delete"
                && !isManagedGcDir resolved.source
              )
              "${machineName}.${deviceName} -> ${resolved.source}"
          )
          machine.devices
        )
    )
    cfg.instances
  );

  invalidCertificateDelegationDirectories =
    lib.filter
    (name: let
      directory = cfg.certificateDelegations.${name}.directory;
    in
      directory == certificateDelegationsRoot || directory == "${certificateDelegationsRoot}/" || !lib.hasPrefix "${certificateDelegationsRoot}/" directory)
    (builtins.attrNames cfg.certificateDelegations);

  certificateDelegationsJson = builtins.toJSON (
    lib.mapAttrs
    (_: delegation: {
      inherit (delegation) directory stateFile;
    })
    cfg.certificateDelegations
  );
  certificateDelegationsFile = pkgs.writeText "incus-machines-certificate-delegations.json" certificateDelegationsJson;

  declaredImagesJson = builtins.toJSON declaredImages;
  declaredInstancesJson = builtins.toJSON (builtins.attrNames cfg.instances);
  instanceProjectsJson = builtins.toJSON (lib.mapAttrs (_name: resolveMachineProject) cfg.instances);
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
        ExecStop = "-${helperScript} stop-instance ${lib.escapeShellArg name} ${lib.escapeShellArg (resolveMachineProject machine)}";
        ExecStart = "${helperScript} machine";
      };
    };

  mkDeviceTmpfiles = _name: machine:
    lib.concatLists (
      lib.mapAttrsToList (
        _devName: dev: let
          resolved = resolveCertDelegationDevice dev;
        in
          lib.optional (isManagedHostDirResolved resolved)
          "d ${resolved.source} 0755 root root -"
      )
      machine.devices
    );

  mkCertificateDelegationTmpfiles = _name: delegation: [
    "d ${delegation.directory} 0755 root root -"
    "f ${delegation.directory}/${delegation.fileName} 0644 root root -"
  ];

  mkCertificateDelegationService = name: delegation: let
    sourceFile = "${delegation.directory}/${delegation.fileName}";
  in
    lib.nameValuePair "incus-cert-delegation-${name}" {
      description = "Reconcile delegated Incus trusted certificates for ${delegation.project}";
      wantedBy = ["sysinit-reactivation.target"];
      after = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
      wants = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
      restartIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME" name)
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_PROJECT" delegation.project)
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_SOURCE_FILE" sourceFile)
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_STATE_FILE" delegation.stateFile)
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME_PREFIX" delegation.namePrefix)
          (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATION_MAX_CERTIFICATES" delegation.maxCertificates)
          certificateDelegationsRootEnv
        ];
        ExecStart = "${helperScript} certificate-delegation";
      };
    };

  mkCertificateDelegationPath = name: delegation: let
    sourceFile = "${delegation.directory}/${delegation.fileName}";
  in
    lib.nameValuePair "incus-cert-delegation-${name}" {
      description = "Watch delegated Incus certificate state for ${delegation.project}";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = sourceFile;
        Unit = "incus-cert-delegation-${name}.service";
      };
    };
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

    preseedMigrations = lib.mkOption {
      type = lib.types.listOf preseedMigrationType;
      default = [
        {
          unsetInstanceConfigKeyPrefixes = ["security.syscalls.intercept."];
        }
      ];
      description = ''
        Best-effort migrations run before upstream `incus-preseed.service`.
        Entries are data-driven so one-time preseed compatibility cleanups can
        live in the shared Incus module instead of host-local systemd overrides.
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

    certificateDelegations = lib.mkOption {
      type = lib.types.attrsOf certificateDelegationType;
      default = {};
      description = ''
        Parent-owned delegated certificate directories. Instances mount these
        by name through `incusLib.mkCertDelegation`, while this module owns
        validation, reconciliation, and cleanup of the host-side directory.
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
          inside at least one listed subnet. Prefer
          `services.incusMachines.remote.projects.<name>.allowedSubnets` for
          project-scoped delegation.
        '';
      };

      projects = lib.mkOption {
        type = lib.types.attrsOf remoteProjectType;
        default = {};
        description = ''
          Project-scoped remote delegation settings. Attribute names are Incus
          project names. Each project can declare its own allowed subnets and
          delegated certificate state to write under
          `/var/lib/incus-delegation/<project>`.
        '';
      };

      certificateDelegation = {
        enable = lib.mkEnableOption ''
          publishing this remote client's public certificate through a mounted
          parent certificate delegation before managing remote resources
        '';

        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Parent-side certificate delegation name. Defaults to the remote
            project, matching the common one-delegation-per-project shape.
          '';
        };

        directory = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Guest-visible directory where the parent delegation is mounted.
            Defaults to `${certificateDelegationGuestRoot}/<name>`.
          '';
        };

        fileName = lib.mkOption {
          type = lib.types.str;
          default = "certs.json";
          description = "Delegated certificate JSON file written under `directory`.";
        };

        certificateName = lib.mkOption {
          type = lib.types.str;
          default = config.networking.hostName;
          description = ''
            Tenant-local certificate name written to the delegated certificate
            file. The parent still applies its configured delegation prefix.
          '';
        };

        waitForTrust = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Wait for the remote Incus API to accept the delegated certificate
            before importing images or reconciling instances.
          '';
        };

        waitTimeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 60;
          description = "Seconds to wait for parent trust reconciliation.";
        };
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
        assertion = invalidInstanceNames == [];
        message =
          "services.incusMachines instance names must match [a-z]([a-z0-9-]{0,61}[a-z0-9])?: "
          + lib.concatStringsSep ", " invalidInstanceNames;
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
        assertion = !cfg.remote.enable || !hasCertificates;
        message = "services.incusMachines.certificates is only supported for local Incus management; use parent-side certificateDelegations or remote.projects for remote targets.";
      }
      {
        assertion = invalidCertificateDelegationNames == [];
        message =
          "services.incusMachines.certificateDelegations names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidCertificateDelegationNames;
      }
      {
        assertion = invalidCertificateDelegationDirectories == [];
        message =
          "services.incusMachines.certificateDelegations directories must be under ${certificateDelegationsRoot}/: "
          + lib.concatStringsSep ", " invalidCertificateDelegationDirectories;
      }
      {
        assertion = invalidCertificateDelegationReferences == [];
        message =
          "services.incusMachines certDelegation devices reference missing certificateDelegations: "
          + lib.concatStringsSep ", " invalidCertificateDelegationReferences;
      }
      {
        assertion = invalidCertificateDelegationDevices == [];
        message =
          "services.incusMachines certDelegation devices must be disk devices: "
          + lib.concatStringsSep ", " invalidCertificateDelegationDevices;
      }
      {
        assertion = unsafeDeleteHostDirs == [];
        message =
          "services.incusMachines disk devices with removalPolicy = \"delete\" must use host paths under "
          + managedGcDirRoot
          + "/: "
          + lib.concatStringsSep ", " unsafeDeleteHostDirs;
      }
      {
        assertion = !invalidRemoteCertificateDelegationName;
        message =
          "services.incusMachines.remote.certificateDelegation.name must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + remoteCertificateDelegationName;
      }
      {
        assertion = invalidRemoteProjectNames == [];
        message =
          "services.incusMachines.remote.projects names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidRemoteProjectNames;
      }
      {
        assertion = invalidRemoteProjectCertificateNames == [];
        message =
          "services.incusMachines.remote.projects cert names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidRemoteProjectCertificateNames;
      }
      {
        assertion = duplicateRemoteProjectCertificateFiles == [];
        message =
          "services.incusMachines.remote.projects cannot publish the same certificate file into multiple project delegations: "
          + lib.concatStringsSep ", " duplicateRemoteProjectCertificateFiles;
      }
      {
        assertion = !cfg.remote.enable || !hasCertificateDelegations;
        message = "services.incusMachines.certificateDelegations is only supported for local Incus management.";
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
        assertion = instancesWithoutRemoteProjectConfig == [];
        message =
          "services.incusMachines remote instances must declare a matching services.incusMachines.remote.projects entry: "
          + lib.concatStringsSep ", " instancesWithoutRemoteProjectConfig;
      }
      {
        assertion = !cfg.remote.enable || instancesOutsideAllowedSubnets == [];
        message =
          "services.incusMachines instances outside remote project allowedSubnets: "
          + lib.concatStringsSep ", " allowedSubnetViolations;
      }
    ];

    virtualisation.incus = {
      enable = lib.mkDefault (!cfg.remote.enable);
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault (!cfg.remote.enable);
    };

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

    systemd = {
      tmpfiles.rules = lib.mkIf (!cfg.remote.enable) (
        lib.unique (
          lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles cfg.instances)
          ++ lib.concatLists (lib.mapAttrsToList mkCertificateDelegationTmpfiles cfg.certificateDelegations)
        )
      );

      services =
        {
          incus-preseed = lib.mkIf hasPreseedMigrations {
            preStart = lib.mkBefore ''
              export INCUS_MACHINES_PRESEED_MIGRATIONS_FILE=${lib.escapeShellArg (toString preseedMigrationsFile)}
              ${helperScript} preseed-migrations
            '';
          };
          incus-machines-certificates = lib.mkIf (!cfg.remote.enable) {
            description = "Reconcile declared Incus trusted certificates";
            wantedBy = ["sysinit-reactivation.target"];
            after = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
            wants = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
            restartTriggers = [
              certificatesFile
            ];
            restartIfChanged = true;
            serviceConfig = {
              Environment = [
                (mkEnvAssignment "INCUS_MACHINES_CERTIFICATES_FILE" certificatesFile)
                (mkEnvAssignment "INCUS_MACHINES_CERTIFICATES_STATE_FILE" certificatesStateFile)
                (mkEnvAssignment "INCUS_MACHINES_LEGACY_CERTIFICATES_STATE_FILE" legacyCertificatesStateFile)
              ];
              Type = "oneshot";
              ExecStart = "${helperScript} certificates";
            };
          };
          incus-cert-delegations-gc = lib.mkIf (!cfg.remote.enable) {
            description = "Garbage-collect removed Incus certificate delegations";
            wantedBy = ["sysinit-reactivation.target"];
            after = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
            wants = ["incus.service"] ++ lib.optional hasIncusPreseed "incus-preseed.service";
            restartTriggers = [
              certificateDelegationsFile
            ];
            restartIfChanged = true;
            serviceConfig = {
              Type = "oneshot";
              Environment = [
                (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATIONS_FILE" certificateDelegationsFile)
                (mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATIONS_STATE_FILE" certificateDelegationsStateFile)
                certificateDelegationsRootEnv
              ];
              ExecStart = "${helperScript} certificate-delegations-gc";
            };
          };
        }
        // lib.mapAttrs' mkCertificateDelegationService cfg.certificateDelegations
        // lib.optionalAttrs hasInstances (let
          incusGcDeps = localIncusDeps ++ ["incus-images.service"];
          incusImagesDeps = localIncusDeps ++ ["network-online.target"];
        in
          {
            incus-remote-project-delegated-certificates = lib.mkIf hasRemoteProjectDelegations {
              description = "Publish remote Incus delegated project certificates";
              before =
                [
                  "incus-images.service"
                  "incus-machines-reconciler.service"
                ]
                ++ map (name: "incus-${name}.service") (builtins.attrNames cfg.instances);
              after = [
                "agenix.service"
                "network-online.target"
              ];
              wants = ["network-online.target"];
              path = [
                pkgs.coreutils
                pkgs.jq
              ];
              restartTriggers = [
                remoteProjectDelegationsFile
              ];
              restartIfChanged = true;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                Environment =
                  [
                    (mkEnvAssignment "INCUS_MACHINES_REMOTE_PROJECT_DELEGATIONS_FILE" remoteProjectDelegationsFile)
                  ]
                  ++ remoteServiceEnvironment;
                ExecStart = "${helperScript} remote-project-delegations";
              };
            };

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
                    (mkEnvAssignment "INCUS_MACHINES_INSTANCE_PROJECTS" instanceProjectsJson)
                  ]
                  ++ remoteServiceEnvironment;
                ExecStart = "${helperScript} reconciler --all";
              };
            };

            incus-images = {
              description = "Import/update declared Incus images";
              wantedBy = ["sysinit-reactivation.target"];
              after = incusImagesDeps ++ remoteProjectDelegationDeps;
              wants = incusImagesDeps;
              requires = remoteProjectDelegationDeps;
              restartTriggers = [
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
                incusGcStateFile
              ];
              restartIfChanged = true;
              serviceConfig = {
                Type = "oneshot";
                Environment =
                  [
                    (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
                    (mkEnvAssignment "INCUS_MACHINES_INSTANCE_PROJECTS" instanceProjectsJson)
                    (mkEnvAssignment "INCUS_MACHINES_MANAGED_GC_DIR_ROOT" managedGcDirRoot)
                  ]
                  ++ remoteServiceEnvironment;
                ExecStart = "${helperScript} gc";
              };
            };
          }
          // lib.mapAttrs' mkMachineService cfg.instances);

      paths = lib.mapAttrs' mkCertificateDelegationPath cfg.certificateDelegations;
    };
  };
}
