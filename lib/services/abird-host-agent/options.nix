{
  lib,
  pkgs,
  ...
}: let
  serviceTargetType = lib.types.submodule {
    options = {
      scope = lib.mkOption {
        type = lib.types.enum ["system" "user"];
        default = "system";
        description = "Systemd manager scope for this local resource unit.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Required user-manager owner when scope is user.";
      };

      unit = lib.mkOption {
        type = lib.types.str;
        description = "Full systemd service or target unit name.";
      };
    };
  };

  readinessCheckType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["path" "tcp" "http"];
        description = "Built-in readiness check type.";
      };
      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Absolute path checked by a path readiness check.";
      };
      requirement = lib.mkOption {
        type = lib.types.enum ["exists" "file" "directory"];
        default = "exists";
        description = "Required path type.";
      };
      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HOST:PORT endpoint for TCP and HTTP readiness checks.";
      };
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "HTTP Host header.";
      };
      httpPath = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "HTTP request path.";
      };
      expectedStatuses = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [200];
        description = "Accepted HTTP response status codes.";
      };
      timeoutMs = lib.mkOption {
        type = lib.types.ints.between 1 300000;
        default = 5000;
        description = "Network readiness timeout in milliseconds.";
      };
    };
  };

  transferType = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = "Absolute source directory visible to this host agent.";
      };
      destination = lib.mkOption {
        type = lib.types.str;
        description = "Absolute destination directory visible to this host agent.";
      };
      rsyncProgram = lib.mkOption {
        type = lib.types.str;
        default = "${pkgs.rsync}/bin/rsync";
        description = "Absolute rsync executable used as the preferred copy engine.";
      };
      tarProgram = lib.mkOption {
        type = lib.types.str;
        default = "${pkgs.gnutar}/bin/tar";
        description = "Absolute local tar executable used for remote fallback copies.";
      };
      remoteSource = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.str;
              description = "Remote source address.";
            };
            user = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Remote SSH user.";
            };
            port = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Remote SSH port.";
            };
            identityFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Absolute SSH identity available to the target agent.";
            };
            sshProgram = lib.mkOption {
              type = lib.types.str;
              default = "${pkgs.openssh}/bin/ssh";
              description = "Absolute SSH executable.";
            };
            sshArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Additional fixed SSH arguments.";
            };
            agentProgram = lib.mkOption {
              type = lib.types.str;
              default = "/run/current-system/sw/bin/abird-host-agent";
              description = "Absolute source host-agent executable.";
            };
            agentPrefix = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Fixed argv placed before the source host-agent executable.";
            };
            rsyncProgram = lib.mkOption {
              type = lib.types.str;
              default = "${pkgs.rsync}/bin/rsync";
              description = "Absolute rsync executable on the source host.";
            };
            rsyncPrefix = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Fixed argv placed before the source rsync executable.";
            };
            tarProgram = lib.mkOption {
              type = lib.types.str;
              default = "${pkgs.gnutar}/bin/tar";
              description = "Absolute tar executable on the source host.";
            };
          };
        });
        default = null;
        description = "Optional source reached over SSH for rsync, tar fallback, and manifest verification.";
      };
      delete = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Delete destination entries absent from the source.";
      };
      fallbackCopy = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use the built-in metadata-preserving filesystem copy if rsync fails.";
      };
    };
  };

  fileStateType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Absolute runtime state file atomically replaced by the agent.";
      };
      content = lib.mkOption {
        type = lib.types.lines;
        description = "Exact state file content.";
      };
      mode = lib.mkOption {
        type = lib.types.ints.between 1 4095;
        default = 420;
        description = "State file mode as an integer (420 is 0644).";
      };
      reloadServices = lib.mkOption {
        type = lib.types.listOf serviceTargetType;
        default = [];
        description = "Services reloaded only after the state file changes successfully.";
      };
    };
  };

  instanceType = lib.types.submodule {
    options = {
      program = lib.mkOption {
        type = lib.types.str;
        default = "${pkgs.incus}/bin/incus";
        description = "Absolute Incus-compatible executable.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "Infrastructure instance name.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        description = "Image reference used when the instance is absent.";
      };
      project = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Incus project.";
      };
      profiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Profiles applied during creation.";
      };
      config = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Fixed instance configuration.";
      };
      devices = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = {};
        description = "Fixed instance device definitions.";
      };
      start = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start the instance after ensuring it exists.";
      };
    };
  };

  deploymentType = lib.types.submodule {
    options = {
      system = lib.mkOption {
        type = lib.types.str;
        description = "Concrete NixOS system closure under /nix/store.";
      };
      mode = lib.mkOption {
        type = lib.types.enum ["switch" "test" "boot"];
        default = "switch";
        description = "switch-to-configuration activation mode.";
      };
    };
  };

  dataRootType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Absolute path owned by this stable named data root.";
      };
      excludes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Exact normalized relative subtrees omitted consistently from copy,
          deletion, backup manifests, and verification.
        '';
      };
    };
  };

  resourceCapabilityOptions = {
    dataPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Absolute local paths in this resource consistency group.";
    };

    dataRoots = lib.mkOption {
      type = lib.types.attrsOf dataRootType;
      default = {};
      description = ''
        Stable named data roots. Use this when a root needs exclusions or when
        source and target paths may differ; dataPaths remains shorthand for
        roots without exclusions.
      '';
    };

    backupConsistency = lib.mkOption {
      type = lib.types.enum ["live" "quiesced"];
      default = "quiesced";
      description = ''
        Whether an automated backup may run while the resource is active.
        Quiesced resources must be held and stopped before their snapshot job.
      '';
    };

    operations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = ''
        Allowlisted local job commands keyed by operation name. Each value is
        an argv list with an absolute executable and no shell expansion.
      '';
    };

    readiness = lib.mkOption {
      type = lib.types.listOf readinessCheckType;
      default = [];
      description = "Built-in local checks required for this resource to be ready.";
    };

    transfers = lib.mkOption {
      type = lib.types.attrsOf transferType;
      default = {};
      description = "Allowlisted local source-to-destination transfer profiles.";
    };

    fileStates = lib.mkOption {
      type = lib.types.attrsOf fileStateType;
      default = {};
      description = "Allowlisted atomic runtime states used for routes and maintenance.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = {};
      description = "Allowlisted infrastructure instance profiles.";
    };

    deployments = lib.mkOption {
      type = lib.types.attrsOf deploymentType;
      default = {};
      description = "Allowlisted NixOS activation profiles.";
    };

    gatedSystemUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional system units blocked while this resource is held.";
    };

    gatedUserUnits = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = ''
        Additional user units blocked while this resource is held, keyed by
        user name.
      '';
    };
  };

  resourceType = lib.types.submodule {
    options =
      resourceCapabilityOptions
      // {
        services = lib.mkOption {
          type = lib.types.listOf serviceTargetType;
          default = [];
          description = ''
            Local lifecycle roots stopped on hold and started only by an
            explicit resource start job. This field belongs to the generic
            resource escape hatch; typed service and instance resources use
            `units` instead.
          '';
        };
      };
  };

  managedResourceType = lib.types.submodule {
    options =
      resourceCapabilityOptions
      // {
        units = lib.mkOption {
          type = lib.types.listOf serviceTargetType;
          default = [];
          description = ''
            Local lifecycle roots stopped on hold and started only by an
            explicit resource start job.
          '';
        };
      };
  };
in {
  options.services.abird-host-agent = {
    enable = lib.mkEnableOption "Abird host-local enforcement agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.abird-host-agent;
      description = "Package providing the abird-host-agent executable.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/abird-host-agent";
      description = "Durable hold and local job state directory.";
    };

    backupRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/abird-host-agent/backups";
      description = "Root for immutable job-scoped resource backup snapshots.";
    };

    rsyncProgram = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.rsync}/bin/rsync";
      description = "Preferred local copy engine for metadata-derived jobs.";
    };

    tarProgram = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.gnutar}/bin/tar";
      description = "Tar executable used by fallback copy jobs.";
    };

    sshHostEd25519PublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public Ed25519 host-key path returned to authenticated transfer
        controllers. Null derives it from services.openssh.hostKeys.
      '';
    };

    brokerTransfer = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          identityFile = lib.mkOption {
            type = lib.types.str;
            description = "Existing controller-only Nixbot private key loaded into an ephemeral per-job SSH agent.";
          };
          sshProgram = lib.mkOption {
            type = lib.types.str;
            default = "${pkgs.openssh}/bin/ssh";
            description = "SSH executable used by controller broker jobs.";
          };
          sshAgentProgram = lib.mkOption {
            type = lib.types.str;
            default = "${pkgs.openssh}/bin/ssh-agent";
            description = "ssh-agent executable used for ephemeral credential delegation.";
          };
          sshAddProgram = lib.mkOption {
            type = lib.types.str;
            default = "${pkgs.openssh}/bin/ssh-add";
            description = "ssh-add executable used to load the existing Nixbot identity.";
          };
          sshArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Fixed SSH arguments for controller-to-source broker sessions.";
          };
        };
      });
      default = null;
      description = ''
        Controller-only transfer policy. The controller agent keeps the
        durable job and forwards an ephemeral authentication socket so source
        and target exchange payload bytes directly through their existing
        sshd and Nixbot sudo lane. No peer identity is installed.
      '';
    };

    nixbotDeploy = {
      enable = lib.mkEnableOption "durable controller-side Nixbot deployments";
      repository = lib.mkOption {
        type = lib.types.str;
        description = "services.nixbot.repos entry used for controller deployments.";
      };
      configOverride = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional controller-local Nixbot inventory override. This is passed
          through NIXBOT_CONFIG_OVERRIDE_PATH while the repository's canonical
          nixbot.nix remains the primary configuration.
        '';
      };
      hostLocalLockPath = lib.mkOption {
        type = lib.types.str;
        default = "/dev/shm/nixbot-host-local.lock.d";
        description = ''
          Nixbot host-local action lock. Durable job recovery defers while a
          controller activation holds this lock, avoiding nested deploy
          deadlocks.
        '';
      };
    };

    manifestPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/abird-host-agent/resources.json";
      readOnly = true;
      description = "Nix-generated immutable local resource manifest.";
    };

    declaredHoldDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/etc/abird-host-agent/declared-holds";
      readOnly = true;
      description = "Immutable cold-start markers for declaratively held resources.";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf managedResourceType;
      default = {};
      description = ''
        Managed service consistency groups keyed by logical name. Names are
        normalized to canonical `service:<name>` resource IDs in the generated
        agent manifest and durable state.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf managedResourceType;
      default = {};
      description = ''
        Managed infrastructure instance consistency groups keyed by logical
        name. Names are normalized to canonical `instance:<name>` resource IDs.
      '';
    };

    extraResources = lib.mkOption {
      type = lib.types.attrsOf resourceType;
      default = {};
      description = ''
        Advanced escape hatch for resource kinds outside the typed service and
        instance namespaces. Keys are complete canonical resource IDs.
      '';
    };

    manageHostResource = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Generate `host:<networking.hostName>` as the aggregate consistency
        group for every managed resource service and data path on this host.
      '';
    };

    hostDataPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Additional host-owned backup roots not already owned by a declared
        service resource. Service data paths are included automatically.
      '';
    };

    declaredHolds = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Bootstrap latches keyed by resource and valued by stable declaration ID.
        A migration transaction may atomically claim a latch without releasing
        the resource. Only transaction activation persists the matching release
        latch, removes the runtime hold, and starts the resource. Removing a
        declaration never releases an existing durable hold.
      '';
    };
  };
}
