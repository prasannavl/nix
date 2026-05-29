{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.incusMachines;
  globalCfg = cfg.global;

  projectConfigs = builtins.removeAttrs cfg ["global"];
  projectLogicalName = projectName: instanceName:
    if projectName == "default"
    then instanceName
    else "${projectName}.${instanceName}";
  projectInstanceEntries = lib.concatLists (
    lib.mapAttrsToList (
      projectName: projectCfg:
        lib.mapAttrsToList (
          instanceName: machine: let
            logicalName = projectLogicalName projectName instanceName;
          in {
            inherit logicalName projectName projectCfg instanceName;
            machine = machine // {project = projectName;};
          }
        )
        projectCfg.instances
    )
    projectConfigs
  );
  allInstances = lib.listToAttrs (
    map (entry: lib.nameValuePair entry.logicalName entry.machine) projectInstanceEntries
  );
  instanceProjectConfigs = lib.listToAttrs (
    map (entry: lib.nameValuePair entry.logicalName entry.projectCfg) projectInstanceEntries
  );
  defaultBaseImage = inputs.self.nixosImages.incus-base;
  defaultBaseAlias = "nixos-incus-base";

  incusMachinesStateDir = "/var/lib/incus-machines";
  managedGcDirRoot = "${incusMachinesStateDir}/managed-dirs";
  certificateDelegationsRoot = "/var/lib/incus-delegations";
  certificateDelegationGuestRoot = "/var/lib/incus-delegation";
  certificateDelegationStateDir = "${incusMachinesStateDir}/delegated-certificates";

  certificatesStateFile = "${incusMachinesStateDir}/certificates.json";
  certificateDelegationsStateFile = "${certificateDelegationStateDir}/delegations.json";

  hasInstances = allInstances != {};
  hasCertificates = globalCfg.certificates != [];
  hasCertificateDelegations = globalCfg.certificateDelegations != {};
  hasRemoteHooks =
    globalCfg.remote.enable
    && (
      hasInstances
      || globalCfg.remote.projects != {}
    );
  hasHostHooks = hasInstances || hasCertificates || hasCertificateDelegations || globalCfg.hostSuspend.enable || hasRemoteHooks;
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
  remoteClientCertificateFile = materializeRemoteFile globalCfg.remote.clientCertificateFile;
  remoteServerCertificateFile = materializeRemoteFile globalCfg.remote.serverCertificateFile;
  remoteEnvExports = lib.optionalString globalCfg.remote.enable ''
    export INCUS_MACHINES_REMOTE_NAME=${lib.escapeShellArg globalCfg.remote.name}
    export INCUS_MACHINES_REMOTE_ADDRESS=${lib.escapeShellArg (remoteValue globalCfg.remote.address)}
    export INCUS_MACHINES_REMOTE_PROJECT=${lib.escapeShellArg remoteClientProject}
    export INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE=${lib.escapeShellArg (remoteValue remoteClientCertificateFile)}
    export INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE=${lib.escapeShellArg (remoteValue globalCfg.remote.clientKeyFile)}
    export INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE=${lib.boolToString globalCfg.remote.acceptCertificate}
    ${lib.optionalString (globalCfg.remote.serverCertificateFile != null)
      "export INCUS_MACHINES_REMOTE_SERVER_CERT_FILE=${lib.escapeShellArg remoteServerCertificateFile}"}
  '';
  remoteServiceEnvironment = lib.optionals globalCfg.remote.enable ([
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_NAME" globalCfg.remote.name)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ADDRESS" (remoteValue globalCfg.remote.address))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_PROJECT" remoteClientProject)
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE" (remoteValue remoteClientCertificateFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE" (remoteValue globalCfg.remote.clientKeyFile))
      (mkEnvAssignment "INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE" (lib.boolToString globalCfg.remote.acceptCertificate))
    ]
    ++ lib.optional (globalCfg.remote.serverCertificateFile != null)
    (mkEnvAssignment "INCUS_MACHINES_REMOTE_SERVER_CERT_FILE" remoteServerCertificateFile));
  remoteProjectDelegationUnit = "incus-remote-project-delegated-certificates.service";
  remoteProjectDelegationDeps = lib.optional hasRemoteProjectDelegations remoteProjectDelegationUnit;
  certificateDelegationsRootEnv =
    mkEnvAssignment "INCUS_MACHINES_CERTIFICATE_DELEGATIONS_ROOT" certificateDelegationsRoot;
  certsPython = pkgs.python3.withPackages (ps: [
    ps.cryptography
  ]);

  helperPackage = pkgs.writeShellApplication {
    name = "incus-machines-helper";
    excludeShellChecks = ["SC1091" "SC2016"];
    runtimeInputs = [
      config.virtualisation.incus.package.client
      pkgs.age
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.git
      pkgs.gnutar
      pkgs.jq
      pkgs.nix
      pkgs.openssl
      pkgs.systemd
      pkgs.xz
    ];
    text = ''
      if [ "''${1:-}" = "certs" ]; then
        shift
        exec ${certsPython}/bin/python ${./helper-certs.py} "$@"
      fi
      source ${./helper.sh}
      main "$@"
    '';
  };
  # Switch-time units must pair new state JSON with the same generation's
  # helper; /run/current-system can still point at the old generation here.
  helperScript = "${helperPackage}/bin/incus-machines-helper";

  reconcilerCommand = pkgs.writeShellScriptBin "incus-machines-reconciler" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_RECONCILE_MODE=${lib.escapeShellArg globalCfg.reconcilePolicy}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_NAMES=${lib.escapeShellArg instanceNamesJson}
    export INCUS_MACHINES_INSTANCE_PROJECTS=${lib.escapeShellArg instanceProjectsJson}
    exec ${helperScript} reconciler "$@"
  '';

  settlementCommand = pkgs.writeShellScriptBin "incus-machines-settlement" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_DECLARED_INSTANCES=${lib.escapeShellArg declaredInstancesJson}
    export INCUS_MACHINES_INSTANCE_NAMES=${lib.escapeShellArg instanceNamesJson}
    export INCUS_MACHINES_INSTANCE_PROJECTS=${lib.escapeShellArg instanceProjectsJson}
    export INCUS_MACHINES_INSTANCE_IPV4_ADDRESSES=${lib.escapeShellArg instanceIpv4AddressesJson}
    export INCUS_MACHINES_INSTANCE_SSH_PORTS=${lib.escapeShellArg instanceSshPortsJson}
    export INCUS_MACHINES_INSTANCE_WAIT_FOR_SSH=${lib.escapeShellArg instanceWaitForSshJson}
    exec ${helperScript} settlement "$@"
  '';

  hostSuspendCommand = pkgs.writeShellScriptBin "incus-machines-host-suspend" ''
    ${remoteEnvExports}
    export INCUS_MACHINES_HOST_SUSPEND_STATE_DIR=${lib.escapeShellArg globalCfg.hostSuspend.stateDir}
    export INCUS_MACHINES_HOST_SUSPEND_DEFAULT_POLICY=${lib.escapeShellArg globalCfg.hostSuspend.defaultPolicy}
    export INCUS_MACHINES_HOST_SUSPEND_INCLUDE_VMS=${lib.boolToString globalCfg.hostSuspend.includeVirtualMachines}
    export INCUS_MACHINES_HOST_SUSPEND_GRACE_TIMEOUT=${toString globalCfg.hostSuspend.graceTimeoutSec}
    export INCUS_MACHINES_HOST_SUSPEND_FORCE_TIMEOUT=${toString globalCfg.hostSuspend.forceTimeoutSec}
    export INCUS_MACHINES_HOST_SUSPEND_RESTART=${lib.boolToString globalCfg.hostSuspend.restart}
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
  preseedStoragePoolNames =
    if incusPreseed == null
    then []
    else map (pool: pool.name) (incusPreseed.storage_pools or []);
  preseedNetworkRefs =
    if incusPreseed == null
    then []
    else map (network: "${network.project or "default"}/${network.name}") (incusPreseed.networks or []);
  preseedProfileRefs =
    if incusPreseed == null
    then []
    else map (profile: "${profile.project or "default"}/${profile.name}") (incusPreseed.profiles or []);
  preseedProfileDeviceRefs =
    if incusPreseed == null
    then []
    else
      lib.concatLists (
        map (
          profile:
            lib.mapAttrsToList
            (deviceName: _: "${profile.project or "default"}/${profile.name}/${deviceName}")
            (profile.devices or {})
        )
        (incusPreseed.profiles or [])
      );
  preseedProjectDeclared = project:
    project == "default" || builtins.elem project preseedProjectNames;
  preseedMigrationHasAction = migration:
    migration.unsetInstanceConfigKeyPrefixes
    != []
    || migration.ensureStoragePools != []
    || migration.ensureNetworks != []
    || migration.ensureProjects != []
    || migration.ensureProfiles != []
    || migration.renameProjects != []
    || migration.renameNetworks != []
    || migration.deleteNetworks != []
    || migration.stopInstances != []
    || migration.startInstances != []
    || migration.deleteInstances != []
    || migration.moveInstancesToStoragePools != []
    || migration.moveStorageVolumes != []
    || migration.setNetworkConfig != []
    || migration.setProjectConfig != []
    || migration.setInstanceDeviceProperties != []
    || migration.setProfileDeviceProperties != [];
  resolvedPreseedMigrations =
    lib.filter
    (migration: migration.projects != [] && preseedMigrationHasAction migration)
    (map (migration: {
        projects =
          if migration.projects == null
          then preseedProjectNames
          else migration.projects;
        inherit (migration) deleteInstances deleteNetworks ensureNetworks ensureProfiles ensureProjects ensureStoragePools moveInstancesToStoragePools moveStorageVolumes renameNetworks renameProjects setInstanceDeviceProperties setNetworkConfig setProfileDeviceProperties setProjectConfig startInstances stopInstances unsetInstanceConfigKeyPrefixes;
      })
      globalCfg.preseedMigrations);
  hasPreseedMigrations = !globalCfg.remote.enable && hasIncusPreseed && resolvedPreseedMigrations != [];
  preseedMigrationsFile = pkgs.writeText "incus-machines-preseed-migrations.json" (builtins.toJSON resolvedPreseedMigrations);
  certificatesJson = builtins.toJSON globalCfg.certificates;
  certificatesFile = pkgs.writeText "incus-machines-certificates.json" certificatesJson;
  invalidRestrictedCertificates = map (cert: cert.name) (
    lib.filter (cert: cert.restricted && cert.projects == []) globalCfg.certificates
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

  effectiveRemoteProjects = globalCfg.remote.projects;
  remoteProjectUserCertificateRefs = lib.unique (
    lib.concatLists (
      lib.mapAttrsToList (_projectName: project: project.userCerts) effectiveRemoteProjects
    )
  );
  missingRemoteProjectUserCertificates =
    lib.filter
    (user: !builtins.hasAttr user globalCfg.remote.userCertificates)
    remoteProjectUserCertificateRefs;
  remoteClientProject =
    if effectiveRemoteProjects != {}
    then builtins.head (builtins.attrNames effectiveRemoteProjects)
    else "default";

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
    project.certs
    ++ map (user: {
      name = user;
      file = materializeRemoteFile globalCfg.remote.userCertificates.${user};
      automatic = false;
    })
    project.userCerts;

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

  hasRemoteProjectDelegations = globalCfg.remote.enable && effectiveRemoteProjects != {};
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
          instance. The named `services.incusMachines.global.certificateDelegations`
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

  remoteProjectType = lib.types.submodule (args @ {name, ...}: let
    projectConfig = args.config;
  in {
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

      userCerts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          User names from `services.incusMachines.global.remote.userCertificates`
          whose generated client certificates should be published into this
          project's delegated certificate state. These are appended to `certs`.
        '';
      };

      includeClientCertificate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to include this remote client's certificate in this project's
          delegated certificate state. Defaults to true so each declared remote
          project can be managed by this controller without repeating the
          controller certificate in `certs`.
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
        default = projectConfig.includeClientCertificate;
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

      ensureNetworks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus network name to create if missing.";
            };

            project = lib.mkOption {
              type = lib.types.str;
              default = "default";
              description = "Incus project containing the managed network.";
            };

            type = lib.mkOption {
              type = lib.types.str;
              description = "Incus network type.";
            };

            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Incus network description.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Incus network config keys.";
            };
          };
        }));
        default = [];
        description = "Networks to create before profile or instance devices are retargeted.";
      };

      setNetworkConfig = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              default = "default";
              description = "Incus project containing the managed network.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus network name to update.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Network config keys to set before other preseed migrations.";
            };

            unsetKeys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Network config keys to unset before setting config.";
            };
          };
        }));
        default = [];
        description = "Network config keys to set or unset before creating replacement networks.";
      };

      ensureProjects = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus project name to create if missing.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Project config keys to set after creation or on existing projects.";
            };
          };
        }));
        default = [];
        description = "Projects to create before preseed applies project changes or cross-project moves.";
      };

      ensureProfiles = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the profile.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus profile name to create if missing.";
            };

            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Profile config keys to set after creation or on existing profiles.";
            };

            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Profile description.";
            };

            devices = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
              default = {};
              description = "Profile devices to add or align after creation or on existing profiles.";
            };
          };
        }));
        default = [];
        description = "Profiles to create or align before preseed applies profile changes or cross-project moves.";
      };

      renameProjects = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            from = lib.mkOption {
              type = lib.types.str;
              description = "Existing Incus project name.";
            };

            to = lib.mkOption {
              type = lib.types.str;
              description = "Desired Incus project name declared by preseed.";
            };
          };
        }));
        default = [];
        description = "Empty project renames to apply before preseed creates or updates projects.";
      };

      renameNetworks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              default = "default";
              description = "Incus project containing the managed network.";
            };

            from = lib.mkOption {
              type = lib.types.str;
              description = "Existing Incus network name.";
            };

            to = lib.mkOption {
              type = lib.types.str;
              description = "Desired Incus network name declared by preseed.";
            };
          };
        }));
        default = [];
        description = "Network renames to apply before preseed creates or updates networks.";
      };

      deleteNetworks = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              default = "default";
              description = "Incus project containing the stale managed network.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus network name to delete if present.";
            };
          };
        }));
        default = [];
        description = "Stale managed networks to delete after consumers are retargeted.";
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

      setInstanceDeviceProperties = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the instance.";
            };

            instance = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name.";
            };

            device = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance device name.";
            };

            properties = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Device properties to set before preseed applies project restrictions.";
            };
          };
        }));
        default = [];
        description = "Existing instance device properties to align before network deletion or project restriction updates.";
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
              description = "Source Incus project containing the instance.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name.";
            };

            targetProject = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional destination project for the instance.";
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
              description = "Source Incus project containing the custom storage volume.";
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

            targetProject = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional destination project for the custom storage volume.";
            };
          };
        }));
        default = [];
        description = "Custom storage volumes to move before disk-device pool changes.";
      };

      stopInstances = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the instance.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name to stop if running.";
            };
          };
        }));
        default = [];
        description = "Instances to stop before volume, project, or storage moves.";
      };

      startInstances = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the instance.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name to start if present and stopped.";
            };
          };
        }));
        default = [];
        description = "Instances to start after migration retargeting completes.";
      };

      deleteInstances = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule (_: {
          options = {
            project = lib.mkOption {
              type = lib.types.str;
              description = "Incus project containing the stale instance.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Incus instance name to delete if present.";
            };
          };
        }));
        default = [];
        description = "Stale instances to delete after their replacement exists elsewhere.";
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

  machineType = lib.types.submodule ({name, ...}: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = ''
          Incus instance name. Defaults to the attribute key under
          `services.incusMachines.<project>.instances`.
        '';
      };

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = ''
          Optional image source for this machine. A string is treated as an
          Incus image reference such as `debian` or `images:debian/12`; a
          non-string value is treated as a NixOS image derivation/system attrset
          to import into local Incus. Defaults to the project default image, or
          `services.incusMachines.global.defaultImage`.
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

  projectType = lib.types.submodule (_: {
    options = {
      defaultImage = lib.mkOption {
        type = lib.types.nullOr lib.types.raw;
        default = null;
        description = ''
          Project-local default image source. When unset, instances use
          `services.incusMachines.global.defaultImage`.
        '';
      };

      defaultImageAlias = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Project-local default image alias. When unset, instances use
          `services.incusMachines.global.defaultImageAlias`.
        '';
      };

      instances = lib.mkOption {
        type = lib.types.attrsOf machineType;
        default = {};
        description = "Declarative Incus containers in this Incus project.";
      };
    };
  });

  resolveCertDelegationDevice = dev:
    if dev.certDelegation == null
    then dev
    else let
      delegation = globalCfg.certificateDelegations.${dev.certDelegation};
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

  resolveMachineProject = machine: machine.project;
  resolveMachineName = _name: machine: machine.name;
  machineProjectNameRef = name: machine: "${resolveMachineProject machine}/${resolveMachineName name machine}";

  createOnlyDevices = machine:
    lib.filterAttrs (_: dev: dev.type != "disk") machine.devices;
  syncableDevices = machine:
    lib.filterAttrs (_: dev: dev.type == "disk") machine.devices;

  configHashPayload = name: machine: {
    preseedTag = globalCfg.preseedTag;
    inherit (machine) config;
    project = resolveMachineProject machine;
    image = let
      resolvedImage = resolveMachineImage name machine;
    in {
      inherit (resolvedImage) alias;
    };
    createOnlyDevices = lib.mapAttrs (resolveDeviceProperties machine) (createOnlyDevices machine);
  };

  configHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON (configHashPayload name machine));

  lifecycleConfigHash = name: machine:
    builtins.hashString "sha256" (builtins.toJSON {
      configHash = configHash name machine;
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
          fileName = globalCfg.certificateDelegations.${resolved.certDelegation}.fileName;
        }
        // lib.optionalAttrs (isManagedHostDirResolved resolved) {inherit (resolved) source;})
      (syncableDevices machine)
    );

  createOnlyDeviceSpecJson = machine:
    builtins.toJSON (lib.mapAttrs (resolveDeviceProperties machine) (createOnlyDevices machine));

  machineRuntimeStateJson = name: machine: let
    instanceName = resolveMachineName name machine;
    instanceImage = instanceImages.${name};
    hash = configHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
    createOnlyDevSpec = createOnlyDeviceSpecJson machine;
    userMetaJson = builtins.toJSON (mkUserMetadata name machine);
    configJson = builtins.toJSON machine.config;
  in
    builtins.toJSON {
      name = instanceName;
      imageTag = globalCfg.imageTag;
      instanceImage = instanceImage;
      imageAlias = instanceImage.alias;
      project = resolveMachineProject machine;
      ipv4Address = machine.ipv4Address;
      configHash = hash;
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
    instanceName = resolveMachineName name machine;
    hash = lifecycleConfigHash name machine;
    diskDevSpec = diskDeviceSpecJson machine;
    diskGcMetadata = diskGcMetadataJson machine;
  in
    builtins.toJSON {
      name = instanceName;
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
      "user.incus-machines.controller" = globalCfg.controllerId;
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
    projectCfg = instanceProjectConfigs.${name};
    hasProjectDefaultImage = projectCfg.defaultImage != null;
    image =
      if machine.image != null
      then machine.image
      else if hasProjectDefaultImage
      then projectCfg.defaultImage
      else globalCfg.defaultImage;
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
      else if projectCfg.defaultImageAlias != null
      then projectCfg.defaultImageAlias
      else globalCfg.defaultImageAlias;
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

  instanceImages = lib.mapAttrs resolveMachineImage allInstances;

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
      ipv4Address = allInstances.${name}.ipv4Address;
    in
      acc
      // {
        ${ipv4Address} = (acc.${ipv4Address} or []) ++ [name];
      })
    {}
    (builtins.attrNames allInstances);

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
    then throw "Invalid IPv4 CIDR for services.incusMachines.global.remote project allowedSubnets: ${subnet}"
    else let
      prefixLength = lib.toInt (builtins.elemAt parts 1);
      size = pow2 (32 - prefixLength);
      base = ipv4ToInt (builtins.elemAt parts 0);
    in
      if prefixLength < 0 || prefixLength > 32
      then throw "Invalid IPv4 CIDR for services.incusMachines.global.remote project allowedSubnets: ${subnet}"
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
        globalCfg.remote.enable
        && !builtins.hasAttr (resolveMachineProject allInstances.${name}) globalCfg.remote.projects
    )
    (builtins.attrNames allInstances);

  instancesOutsideAllowedSubnets =
    lib.filter (
      name: let
        project = resolveMachineProject allInstances.${name};
        subnets = remoteProjectSubnets project;
      in
        subnets
        != []
        && !lib.any
        (subnet: ipv4InCidr allInstances.${name}.ipv4Address subnet)
        subnets
    )
    (builtins.attrNames allInstances);

  allowedSubnetViolations =
    map (
      name: let
        project = resolveMachineProject allInstances.${name};
      in "${name} (${project}, ${allInstances.${name}.ipv4Address})"
    )
    instancesOutsideAllowedSubnets;

  invalidCertificateDelegationNames =
    lib.filter
    (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
    (builtins.attrNames globalCfg.certificateDelegations);

  invalidRemoteProjectNames =
    lib.filter
    (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
    (builtins.attrNames globalCfg.remote.projects);

  invalidResolvedInstanceNames =
    lib.filter
    (name: builtins.match "[a-z]([a-z0-9-]{0,61}[a-z0-9])?" (resolveMachineName name allInstances.${name}) == null)
    (builtins.attrNames allInstances);

  instanceRefToMachineNames =
    lib.foldl'
    (acc: name: let
      ref = machineProjectNameRef name allInstances.${name};
    in
      acc
      // {
        ${ref} = (acc.${ref} or []) ++ [name];
      })
    {}
    (builtins.attrNames allInstances);

  duplicateInstanceRefs =
    lib.attrNames
    (lib.filterAttrs (_ref: machineNames: builtins.length machineNames > 1) instanceRefToMachineNames);

  instanceRefConflicts =
    map
    (ref: "${ref} -> ${lib.concatStringsSep ", " instanceRefToMachineNames.${ref}}")
    duplicateInstanceRefs;

  invalidRemoteProjectCertificateNames = lib.concatLists (
    lib.mapAttrsToList (
      projectName: project:
        lib.filter
        (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name == null)
        (map (cert: cert.name) (remoteProjectCertificates projectName project))
    )
    effectiveRemoteProjects
  );

  invalidInstanceNames =
    lib.concatMap
    (entry:
      lib.optional
      (builtins.match "[a-z]([a-z0-9-]{0,61}[a-z0-9])?" entry.instanceName == null)
      "${entry.projectName}.${entry.instanceName}")
    projectInstanceEntries;

  invalidCertificateDelegationReferences = lib.concatLists (
    lib.mapAttrsToList (
      machineName: machine:
        lib.concatLists (
          lib.mapAttrsToList (
            deviceName: dev:
              lib.optional
              (dev.certDelegation != null && !builtins.hasAttr dev.certDelegation globalCfg.certificateDelegations)
              "${machineName}.${deviceName} -> ${dev.certDelegation}"
          )
          machine.devices
        )
    )
    allInstances
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
    allInstances
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
    allInstances
  );

  invalidCertificateDelegationDirectories =
    lib.filter
    (name: let
      directory = globalCfg.certificateDelegations.${name}.directory;
    in
      directory == certificateDelegationsRoot || directory == "${certificateDelegationsRoot}/" || !lib.hasPrefix "${certificateDelegationsRoot}/" directory)
    (builtins.attrNames globalCfg.certificateDelegations);

  preseedMigrationsWithActions = lib.filter preseedMigrationHasAction globalCfg.preseedMigrations;
  invalidPreseedMigrationEnsureStoragePools = lib.concatLists (
    map (
      migration:
        map
        (pool: "ensureStoragePools.${pool.name} is not declared in virtualisation.incus.preseed.storage_pools")
        (lib.filter (pool: !builtins.elem pool.name preseedStoragePoolNames) migration.ensureStoragePools)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationEnsureNetworks = lib.concatLists (
    map (
      migration:
        map
        (network: "ensureNetworks ${network.project}/${network.name} is not declared in virtualisation.incus.preseed.networks")
        (lib.filter (network: !builtins.elem "${network.project}/${network.name}" preseedNetworkRefs) migration.ensureNetworks)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationEnsureProjects = lib.concatLists (
    map (
      migration:
        map
        (entry: "ensureProjects.${entry.name} is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !builtins.elem entry.name preseedProjectNames) migration.ensureProjects)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationEnsureProfiles = lib.concatLists (
    map (
      migration:
        map
        (entry: "ensureProfiles ${entry.project}/${entry.name} is not declared in virtualisation.incus.preseed.profiles")
        (lib.filter (entry: !builtins.elem "${entry.project}/${entry.name}" preseedProfileRefs) migration.ensureProfiles)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationRenameProjects = lib.concatLists (
    map (
      migration:
        lib.concatLists (
          map
          (rename:
            lib.optionals (rename.from == rename.to) [
              "renameProjects ${rename.from} -> ${rename.to} uses the same source and target"
            ]
            ++ lib.optionals (rename.from == "default" || rename.to == "default") [
              "renameProjects ${rename.from} -> ${rename.to} cannot rename the default project"
            ]
            ++ lib.optionals (!builtins.elem rename.to preseedProjectNames) [
              "renameProjects ${rename.from} -> ${rename.to} target is not declared in virtualisation.incus.preseed.projects"
            ])
          migration.renameProjects
        )
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationRenameNetworks = lib.concatLists (
    map (
      migration:
        lib.concatLists (
          map
          (rename: let
            targetRef = "${rename.project}/${rename.to}";
          in
            lib.optionals (rename.from == rename.to) [
              "renameNetworks ${rename.project}/${rename.from} -> ${rename.to} uses the same source and target"
            ]
            ++ lib.optionals (!builtins.elem targetRef preseedNetworkRefs) [
              "renameNetworks ${rename.project}/${rename.from} -> ${rename.to} target is not declared in virtualisation.incus.preseed.networks"
            ])
          migration.renameNetworks
        )
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationDeleteNetworks = lib.concatLists (
    map (
      migration:
        map
        (network: "deleteNetworks ${network.project}/${network.name} is still declared in virtualisation.incus.preseed.networks")
        (lib.filter (network: builtins.elem "${network.project}/${network.name}" preseedNetworkRefs) migration.deleteNetworks)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationSetNetworkConfig = lib.concatLists (
    map (
      migration:
        map
        (entry: "setNetworkConfig ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !preseedProjectDeclared entry.project) migration.setNetworkConfig)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationSetProjectConfig = lib.concatLists (
    map (
      migration:
        map
        (entry: "setProjectConfig.${entry.project} is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !preseedProjectDeclared entry.project) migration.setProjectConfig)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationSetProfileDeviceProperties = lib.concatLists (
    map (
      migration:
        map
        (entry: "setProfileDeviceProperties ${entry.project}/${entry.profile}/${entry.device} is not declared in virtualisation.incus.preseed.profiles")
        (lib.filter (entry: !builtins.elem "${entry.project}/${entry.profile}/${entry.device}" preseedProfileDeviceRefs) migration.setProfileDeviceProperties)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationSetInstanceDeviceProperties = lib.concatLists (
    map (
      migration:
        lib.concatLists (
          map
          (entry:
            lib.optionals (!preseedProjectDeclared entry.project) [
              "setInstanceDeviceProperties ${entry.project}/${entry.instance}/${entry.device} project is not declared in virtualisation.incus.preseed.projects"
            ]
            ++ lib.optionals (builtins.hasAttr "network" entry.properties && !builtins.elem "default/${entry.properties.network}" preseedNetworkRefs) [
              "setInstanceDeviceProperties ${entry.project}/${entry.instance}/${entry.device} network ${entry.properties.network} is not declared in virtualisation.incus.preseed.networks"
            ])
          migration.setInstanceDeviceProperties
        )
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationStopInstances = lib.concatLists (
    map (
      migration:
        map
        (entry: "stopInstances ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !preseedProjectDeclared entry.project) migration.stopInstances)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationStartInstances = lib.concatLists (
    map (
      migration:
        map
        (entry: "startInstances ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !preseedProjectDeclared entry.project) migration.startInstances)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationDeleteInstances = lib.concatLists (
    map (
      migration:
        map
        (entry: "deleteInstances ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects")
        (lib.filter (entry: !preseedProjectDeclared entry.project) migration.deleteInstances)
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationMoveInstancesToStoragePools = lib.concatLists (
    map (
      migration:
        lib.concatLists (
          map
          (entry: let
            targetProject =
              if entry.targetProject == null
              then entry.project
              else entry.targetProject;
          in
            lib.optionals (!preseedProjectDeclared entry.project) [
              "moveInstancesToStoragePools ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects"
            ]
            ++ lib.optionals (!preseedProjectDeclared targetProject) [
              "moveInstancesToStoragePools ${entry.project}/${entry.name} target project ${targetProject} is not declared in virtualisation.incus.preseed.projects"
            ]
            ++ lib.optionals (!builtins.elem entry.pool preseedStoragePoolNames) [
              "moveInstancesToStoragePools ${entry.project}/${entry.name} target pool ${entry.pool} is not declared in virtualisation.incus.preseed.storage_pools"
            ])
          migration.moveInstancesToStoragePools
        )
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationMoveStorageVolumes = lib.concatLists (
    map (
      migration:
        lib.concatLists (
          map
          (entry: let
            targetProject =
              if entry.targetProject == null
              then entry.project
              else entry.targetProject;
          in
            lib.optionals (!preseedProjectDeclared entry.project) [
              "moveStorageVolumes ${entry.project}/${entry.name} project is not declared in virtualisation.incus.preseed.projects"
            ]
            ++ lib.optionals (!preseedProjectDeclared targetProject) [
              "moveStorageVolumes ${entry.project}/${entry.name} target project ${targetProject} is not declared in virtualisation.incus.preseed.projects"
            ]
            ++ lib.optionals (!builtins.elem entry.toPool preseedStoragePoolNames) [
              "moveStorageVolumes ${entry.project}/${entry.name} target pool ${entry.toPool} is not declared in virtualisation.incus.preseed.storage_pools"
            ])
          migration.moveStorageVolumes
        )
    )
    globalCfg.preseedMigrations
  );
  invalidPreseedMigrationTargets =
    invalidPreseedMigrationEnsureStoragePools
    ++ invalidPreseedMigrationEnsureNetworks
    ++ invalidPreseedMigrationEnsureProjects
    ++ invalidPreseedMigrationEnsureProfiles
    ++ invalidPreseedMigrationRenameProjects
    ++ invalidPreseedMigrationRenameNetworks
    ++ invalidPreseedMigrationDeleteNetworks
    ++ invalidPreseedMigrationSetNetworkConfig
    ++ invalidPreseedMigrationSetProjectConfig
    ++ invalidPreseedMigrationSetProfileDeviceProperties
    ++ invalidPreseedMigrationSetInstanceDeviceProperties
    ++ invalidPreseedMigrationStopInstances
    ++ invalidPreseedMigrationStartInstances
    ++ invalidPreseedMigrationDeleteInstances
    ++ invalidPreseedMigrationMoveInstancesToStoragePools
    ++ invalidPreseedMigrationMoveStorageVolumes;

  certificateDelegationsJson = builtins.toJSON (
    lib.mapAttrs
    (_: delegation: {
      inherit (delegation) directory stateFile;
    })
    globalCfg.certificateDelegations
  );
  certificateDelegationsFile = pkgs.writeText "incus-machines-certificate-delegations.json" certificateDelegationsJson;

  declaredImagesJson = builtins.toJSON declaredImages;
  declaredInstancesJson = builtins.toJSON (builtins.attrNames allInstances);
  instanceNamesJson = builtins.toJSON (lib.mapAttrs resolveMachineName allInstances);
  instanceProjectsJson = builtins.toJSON (lib.mapAttrs (_name: resolveMachineProject) allInstances);
  declaredInstanceRefsJson = builtins.toJSON (
    lib.listToAttrs (
      map
      (name: lib.nameValuePair (machineProjectNameRef name allInstances.${name}) true)
      (builtins.attrNames allInstances)
    )
  );
  instanceIpv4AddressesJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.ipv4Address) allInstances);
  instanceSshPortsJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.sshPort) allInstances);
  instanceWaitForSshJson = builtins.toJSON (lib.mapAttrs (_name: instance: instance.waitForSsh) allInstances);
  gcProjects = lib.unique (
    lib.optionals globalCfg.remote.enable (
      builtins.attrNames effectiveRemoteProjects
      ++ builtins.attrValues (lib.mapAttrs (_name: resolveMachineProject) allInstances)
    )
  );
  gcProjectsJson = builtins.toJSON gcProjects;
  incusImagesStateFile = pkgs.writeText "incus-machines-images-state.json" (builtins.toJSON {
    imageTag = globalCfg.imageTag;
    images = declaredImages;
  });
  incusGcStateFile = pkgs.writeText "incus-machines-gc-state.json" (builtins.toJSON {
    instances = builtins.attrNames allInstances;
    instanceNames = lib.mapAttrs resolveMachineName allInstances;
    instanceProjects = lib.mapAttrs (_name: resolveMachineProject) allInstances;
    instanceRefs = builtins.attrNames (builtins.fromJSON declaredInstanceRefsJson);
    controllerId = globalCfg.controllerId;
    projects = gcProjects;
    remote = globalCfg.remote.enable;
  });
  localIncusDeps = lib.optional (!globalCfg.remote.enable) "incus-preseed.service";
  incusLifecycleDeps =
    localIncusDeps
    ++ remoteProjectDelegationDeps
    ++ [
      "network-online.target"
      "incus-images.service"
    ];

  mkMachineService = name: machine: let
    instanceName = resolveMachineName name machine;
    lifecycleStateFile = pkgs.writeText "incus-machine-${name}-lifecycle-state.json" (machineLifecycleStateJson name machine);
  in
    lib.nameValuePair "incus-${name}" {
      description = "Incus container lifecycle for ${resolveMachineProject machine}/${instanceName}";
      wantedBy = ["multi-user.target"];
      after = incusLifecycleDeps;
      wants = incusLifecycleDeps;
      requires = localIncusDeps ++ remoteProjectDelegationDeps ++ ["incus-images.service"];
      restartTriggers = [lifecycleStateFile];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment =
          [
            (mkEnvAssignment "INCUS_MACHINES_INSTANCE_STATE_FILE" "/etc/incus-machines/${name}.json")
          ]
          ++ remoteServiceEnvironment;
        ExecStop = "-${helperScript} stop-instance ${lib.escapeShellArg instanceName} ${lib.escapeShellArg (resolveMachineProject machine)}";
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
  options.services.incusMachines = lib.mkOption {
    default = {};
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf projectType;
      options.global = {
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

        controllerId = lib.mkOption {
          type = lib.types.str;
          default = config.networking.hostName;
          description = ''
            Stable owner identifier written to managed Incus instances. Remote GC
            uses this marker to delete only instances owned by this delegated
            controller, even when multiple repo-managed controllers share a parent
            Incus daemon or project.
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
          default = [];
          description = ''
            Explicit best-effort migrations run before upstream
            `incus-preseed.service`. Use these for durable, data-driven Incus
            fabric transitions that must happen before preseed applies project
            restrictions, profile changes, or storage changes.
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

          userCertificates = lib.mkOption {
            type = lib.types.attrsOf remoteProjectCertFileType;
            default = {};
            description = ''
              User-name to PEM certificate file mapping used by
              `services.incusMachines.global.remote.projects.<name>.userCerts`.
              This lets each project compose raw `certs` with generated user
              certificates without repeating certificate paths in every project.
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
          "services.incusMachines instance keys must match [a-z]([a-z0-9-]{0,61}[a-z0-9])?: "
          + lib.concatStringsSep ", " invalidInstanceNames;
      }
      {
        assertion = invalidResolvedInstanceNames == [];
        message =
          "services.incusMachines Incus instance names must match [a-z]([a-z0-9-]{0,61}[a-z0-9])?: "
          + lib.concatStringsSep ", " invalidResolvedInstanceNames;
      }
      {
        assertion = instanceRefConflicts == [];
        message =
          "services.incusMachines has duplicate Incus project/name assignments: "
          + lib.concatStringsSep "; " instanceRefConflicts;
      }
      {
        assertion = preseedCertificates == [];
        message = "Use services.incusMachines.global.certificates instead of virtualisation.incus.preseed.certificates.";
      }
      {
        assertion = hasIncusPreseed || preseedMigrationsWithActions == [];
        message = "services.incusMachines.global.preseedMigrations requires virtualisation.incus.preseed.";
      }
      {
        assertion = invalidPreseedMigrationTargets == [];
        message =
          "services.incusMachines.global.preseedMigrations reference undeclared or invalid preseed targets: "
          + lib.concatStringsSep "; " invalidPreseedMigrationTargets;
      }
      {
        assertion = invalidRestrictedCertificates == [];
        message =
          "services.incusMachines.global.certificates restricted certificates must declare at least one project: "
          + lib.concatStringsSep ", " invalidRestrictedCertificates;
      }
      {
        assertion = !globalCfg.remote.enable || !hasCertificates;
        message = "services.incusMachines.global.certificates is only supported for local Incus management; use parent-side certificateDelegations or remote.projects for remote targets.";
      }
      {
        assertion = invalidCertificateDelegationNames == [];
        message =
          "services.incusMachines.global.certificateDelegations names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidCertificateDelegationNames;
      }
      {
        assertion = invalidCertificateDelegationDirectories == [];
        message =
          "services.incusMachines.global.certificateDelegations directories must be under ${certificateDelegationsRoot}/: "
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
        assertion = invalidRemoteProjectNames == [];
        message =
          "services.incusMachines.global.remote.projects names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidRemoteProjectNames;
      }
      {
        assertion = invalidRemoteProjectCertificateNames == [];
        message =
          "services.incusMachines.global.remote.projects cert names must match [A-Za-z0-9][A-Za-z0-9_.-]*: "
          + lib.concatStringsSep ", " invalidRemoteProjectCertificateNames;
      }
      {
        assertion = missingRemoteProjectUserCertificates == [];
        message =
          "services.incusMachines.global.remote.projects userCerts must exist in services.incusMachines.global.remote.userCertificates: "
          + lib.concatStringsSep ", " missingRemoteProjectUserCertificates;
      }
      {
        assertion = !globalCfg.remote.enable || !hasCertificateDelegations;
        message = "services.incusMachines.global.certificateDelegations is only supported for local Incus management.";
      }
      {
        assertion = !globalCfg.remote.enable || globalCfg.remote.name != "local";
        message = "services.incusMachines.global.remote.name must not be 'local' when remote mode is enabled.";
      }
      {
        assertion = !globalCfg.remote.enable || globalCfg.remote.address != null;
        message = "services.incusMachines.global.remote.address is required when remote mode is enabled.";
      }
      {
        assertion = !globalCfg.remote.enable || globalCfg.remote.clientCertificateFile != null;
        message = "services.incusMachines.global.remote.clientCertificateFile is required when remote mode is enabled.";
      }
      {
        assertion = !globalCfg.remote.enable || globalCfg.remote.clientKeyFile != null;
        message = "services.incusMachines.global.remote.clientKeyFile is required when remote mode is enabled.";
      }
      {
        assertion = !globalCfg.remote.enable || globalCfg.remote.serverCertificateFile != null || globalCfg.remote.acceptCertificate;
        message = "services.incusMachines.global.remote must set serverCertificateFile or acceptCertificate = true.";
      }
      {
        assertion = !globalCfg.remote.enable || !globalCfg.hostSuspend.enable;
        message = "services.incusMachines.global.hostSuspend is only supported for local Incus management.";
      }
      {
        assertion = instancesWithoutRemoteProjectConfig == [];
        message =
          "services.incusMachines remote instances must declare a matching services.incusMachines.global.remote.projects entry: "
          + lib.concatStringsSep ", " instancesWithoutRemoteProjectConfig;
      }
      {
        assertion = !globalCfg.remote.enable || instancesOutsideAllowedSubnets == [];
        message =
          "services.incusMachines instances outside remote project allowedSubnets: "
          + lib.concatStringsSep ", " allowedSubnetViolations;
      }
    ];

    virtualisation.incus = {
      enable = lib.mkDefault (!globalCfg.remote.enable);
      package = lib.mkDefault pkgs.incus;
      ui.enable = lib.mkDefault (!globalCfg.remote.enable);
    };

    environment.systemPackages = [
      helperPackage
      reconcilerCommand
      settlementCommand
      hostSuspendCommand
    ];

    powerManagement = lib.mkIf globalCfg.hostSuspend.enable {
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
      allInstances
    );

    systemd = {
      tmpfiles.rules = lib.mkIf (!globalCfg.remote.enable) (
        lib.unique (
          lib.concatLists (lib.mapAttrsToList mkDeviceTmpfiles allInstances)
          ++ lib.concatLists (lib.mapAttrsToList mkCertificateDelegationTmpfiles globalCfg.certificateDelegations)
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
          incus-machines-certificates = lib.mkIf (!globalCfg.remote.enable) {
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
              ];
              Type = "oneshot";
              ExecStart = "${helperScript} certificates";
            };
          };
          incus-cert-delegations-gc = lib.mkIf (!globalCfg.remote.enable) {
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
        // lib.mapAttrs' mkCertificateDelegationService globalCfg.certificateDelegations
        // (let
          incusGcDeps =
            localIncusDeps
            ++ remoteProjectDelegationDeps
            ++ lib.optional hasInstances "incus-images.service";
          incusImagesDeps = localIncusDeps ++ ["network-online.target"];
        in
          lib.optionalAttrs hasRemoteProjectDelegations {
            incus-remote-project-delegated-certificates = lib.mkIf hasRemoteProjectDelegations {
              description = "Publish remote Incus delegated project certificates";
              before =
                [
                  "incus-images.service"
                  "incus-machines-reconciler.service"
                ]
                ++ map (name: "incus-${name}.service") (builtins.attrNames allInstances);
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
          }
          // lib.optionalAttrs hasInstances {
            incus-machines-reconciler = lib.mkIf (globalCfg.reconcilePolicy != "off") {
              description = "Reconciler for declared Incus guests";
              wantedBy = lib.optional globalCfg.autoReconcile "multi-user.target";
              after = incusLifecycleDeps;
              wants = incusLifecycleDeps;
              serviceConfig = {
                Type = "oneshot";
                Environment =
                  [
                    (mkEnvAssignment "INCUS_MACHINES_RECONCILE_MODE" globalCfg.reconcilePolicy)
                    (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCES" declaredInstancesJson)
                    (mkEnvAssignment "INCUS_MACHINES_INSTANCE_NAMES" instanceNamesJson)
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
                    (mkEnvAssignment "INCUS_MACHINES_IMAGE_TAG" globalCfg.imageTag)
                    (mkEnvAssignment "INCUS_MACHINES_DECLARED_IMAGES" declaredImagesJson)
                  ]
                  ++ remoteServiceEnvironment;
                ExecStart = "${helperScript} images";
              };
            };
          }
          // lib.optionalAttrs (hasInstances || hasRemoteHooks) {
            incus-machines-gc = {
              description = "Garbage-collect Incus containers no longer declared in NixOS config";
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
                    (mkEnvAssignment "INCUS_MACHINES_DECLARED_INSTANCE_REFS" declaredInstanceRefsJson)
                    (mkEnvAssignment "INCUS_MACHINES_INSTANCE_NAMES" instanceNamesJson)
                    (mkEnvAssignment "INCUS_MACHINES_INSTANCE_PROJECTS" instanceProjectsJson)
                    (mkEnvAssignment "INCUS_MACHINES_MANAGED_GC_DIR_ROOT" managedGcDirRoot)
                    (mkEnvAssignment "INCUS_MACHINES_CONTROLLER_ID" globalCfg.controllerId)
                    (mkEnvAssignment "INCUS_MACHINES_GC_PROJECTS" gcProjectsJson)
                  ]
                  ++ remoteServiceEnvironment;
                ExecStart = "${helperScript} gc";
              };
            };
          }
          // lib.mapAttrs' mkMachineService allInstances);

      paths = lib.mapAttrs' mkCertificateDelegationPath globalCfg.certificateDelegations;
    };
  };
}
