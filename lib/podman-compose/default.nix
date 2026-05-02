{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.services.podmanCompose;
  hasStacks = cfg != {};
  collectionsLib = import ../flake/collections {lib = lib;};
  exposedPortsLib = import ../services/exposed-ports {inherit lib;};
  nginxLib = import ../services/nginx {inherit lib;};
  cloudflareTunnelsLib = import ../services/tunnels/cloudflare.nix {inherit lib;};
  defaultService = {
    source = null;
    files = {};
    entryFile = null;
    user = null;
    workingDir = null;
    serviceName = null;
    serviceOverrides = {};
    composeArgs = [];
    autoStart = true;
    recreateOnSwitch = false;
    bootTag = "0";
    recreateTag = "0";
    imageTag = "0";
    dependsOn = [];
    wants = [];
    waitForNetwork = true;
    envSecrets = {};
    fileSecrets = {};
    dirs = {};
    exposedPorts = {};
  };
  bootReadyTargetName = "systemd-user-manager-ready.target";

  ownerRefType = lib.types.either lib.types.str lib.types.int;
  modeOptionType = lib.types.nullOr lib.types.str;
  ownerScopeType = lib.types.enum ["host" "container"];
  ownerEntryDefaults = mode: {
    mode = mode;
    user = null;
    group = null;
    userScope = "host";
  };
  dirEntryDefaults = ownerEntryDefaults "0750";
  fileEntryDefaults =
    ownerEntryDefaults "none"
    // {
      text = null;
      source = null;
    };
  fileSecretEntryDefaults =
    ownerEntryDefaults "0400"
    // {
      mount = true;
      mountPath = null;
      readOnly = true;
      services = null;
    };
  envSecretEntryDefaults = ownerEntryDefaults "0400";

  ownerOptions = {
    modeDefault,
    modeDescription,
    userDescription ? "Owner for the staged file. Numeric uid or name. When null, unchanged.",
    groupDescription ? "Group for the staged file. Numeric gid or name. When null, unchanged.",
  }: {
    mode = lib.mkOption {
      type = modeOptionType;
      default = modeDefault;
      description = modeDescription;
    };
    user = lib.mkOption {
      type = lib.types.nullOr ownerRefType;
      default = (ownerEntryDefaults modeDefault).user;
      description = userDescription;
    };
    group = lib.mkOption {
      type = lib.types.nullOr ownerRefType;
      default = (ownerEntryDefaults modeDefault).group;
      description = groupDescription;
    };
    userScope = lib.mkOption {
      type = ownerScopeType;
      default = (ownerEntryDefaults modeDefault).userScope;
      description = "Whether user/group refer to host identities or to identities inside the container user namespace. Container scope requires numeric user/group and chowns via `podman unshare`.";
    };
  };
  dirEntryOptions = ownerOptions {
    modeDefault = dirEntryDefaults.mode;
    modeDescription = "Octal mode string applied to the staged directory.";
    userDescription = "Owner for the staged directory. Numeric uid or name. When null, unchanged.";
    groupDescription = "Group for the staged directory. Numeric gid or name. When null, unchanged.";
  };
  dirEntryType = lib.types.submodule {options = dirEntryOptions;};

  fileEntryOptions =
    {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = fileEntryDefaults.text;
        description = "Literal file contents. Mutually exclusive with source.";
      };
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = fileEntryDefaults.source;
        description = "Host path to copy contents from. Directories are expanded recursively under the destination path. Mutually exclusive with text.";
      };
    }
    // (ownerOptions {
      modeDefault = fileEntryDefaults.mode;
      modeDescription = "Octal mode string like \"0644\" applied after staging, or \"none\" to preserve the copied source mode.";
      userDescription = "Owner for the staged file. Numeric uid or name. When null, the stack user (ownership unchanged post-copy) is used.";
    });
  fileEntrySubmoduleType = lib.types.submodule {options = fileEntryOptions;};
  fileEntryType =
    lib.types.coercedTo
    lib.types.path
    (v: {source = v;})
    (lib.types.coercedTo lib.types.lines (v: {text = v;}) fileEntrySubmoduleType);

  fileSecretEntryOptions =
    {
      file = lib.mkOption {
        type = lib.types.str;
        description = "Host path to the source secret file (for example an age-decrypted drop under /run/agenix).";
      };
    }
    // (ownerOptions {
      modeDefault = fileSecretEntryDefaults.mode;
      modeDescription = "Octal mode string applied to the staged secret file.";
    })
    // {
      mount = lib.mkOption {
        type = lib.types.bool;
        default = fileSecretEntryDefaults.mount;
        description = "Auto-mount the staged secret into target compose services via a generated override. Disable to skip the override and mount explicitly from the main source.";
      };
      mountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = fileSecretEntryDefaults.mountPath;
        description = "In-container mount path. When null, defaults to `/run/secrets/<name>`.";
      };
      services = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = fileSecretEntryDefaults.services;
        description = "Compose services that should receive the auto-mount. When null, resolves to every service declared in an attrs-shaped `source`, otherwise falls back to a single service named after the instance.";
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = fileSecretEntryDefaults.readOnly;
        description = "Whether the auto-mount should be read-only (`:ro`). Only meaningful when `mount = true`.";
      };
    };
  fileSecretEntrySubmoduleType = lib.types.submodule {options = fileSecretEntryOptions;};
  fileSecretEntryType =
    lib.types.coercedTo
    lib.types.str
    (v: {file = v;})
    fileSecretEntrySubmoduleType;

  ownerRefToString = v:
    if v == null
    then null
    else if builtins.isInt v
    then toString v
    else v;
  isOwnerNumeric = v:
    v == null || builtins.isInt v || (builtins.match "[0-9]+" v != null);
  isSkippedMode = mode: mode == null || mode == "none";
  isOctalMode = mode: isSkippedMode mode || builtins.match "[0-7]?[0-7][0-7][0-7]" mode != null;
  dirModeHasSearchBit = mode:
    isSkippedMode mode
    || builtins.match "[0-7]?([1357][0-7][0-7]|[0-7][1357][0-7]|[0-7][0-7][1357])" mode
    != null;

  helperPackage = pkgs.writeShellApplication {
    name = "podman-compose-helper";
    excludeShellChecks = ["SC1091"];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.podman
      pkgs.systemd
    ];
    text = ''
      source ${./helper.sh}
      main "$@"
    '';
  };
  helperScript = "${helperPackage}/bin/podman-compose-helper";

  serviceType = lib.types.submodule (_: {
    options = {
      source = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.lines lib.types.attrs lib.types.path]);
        default = null;
        description = "Main compose source content. Attrsets are rendered to YAML; strings are copied as-is; paths are used directly.";
      };

      files = lib.mkOption {
        type = lib.types.attrsOf fileEntryType;
        default = {};
        description = ''
          Additional files keyed by destination path. Each value is a file entry
          submodule with text/source plus optional mode/user/group/userScope.
          String and path shorthands coerce to `{ text = ...; }` or
          `{ source = ...; }`. The default `mode = "none"` preserves the copied
          source mode. Path sources that point to a directory expand recursively
          under the destination path, with each expanded child inheriting the
          parent's permission fields.
        '';
      };

      dirs = lib.mkOption {
        type = lib.types.attrsOf dirEntryType;
        default = {};
        description = ''
          Managed staged directories keyed by destination path under the compose
          working directory. Each entry carries mode/user/group/userScope, and
          is finalized after file staging so directory bind mounts can avoid
          world traversal bits.
        '';
      };

      entryFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.str (lib.types.listOf lib.types.str)]);
        default = null;
        description = "Optional compose entry filename(s) inside workingDir. Set a string for one file or a list for ordered repeated `-f` arguments. When null and source is set, `compose.yml` in workingDir is used; otherwise podman compose default file discovery is used in workingDir.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override user for this service.";
      };

      workingDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override working directory for podman compose project context.";
      };

      sourcePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        readOnly = true;
        internal = true;
        description = "Resolved source paths by filename.";
      };

      envSecretRuntimePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Staged host paths for generated env secret files by compose service.";
      };

      fileSecretRuntimePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Staged host paths for file-based secrets by secret name.";
      };

      dirRuntimePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Resolved runtime paths by managed directory.";
      };

      runtimePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Resolved runtime paths by filename.";
      };

      serviceName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override generated systemd user service name.";
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Extra attributes merged into generated systemd.user.services.<name>.";
      };

      composeArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional arguments passed to every `podman compose` invocation for this instance, before compose-file flags and the subcommand.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this compose instance should be auto-started by the generated user-manager reconcile flow during deploy and boot-ready startup.";
      };

      recreateOnSwitch = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether service starts triggered by switch/restart should force container recreation instead of reusing existing compose containers.";
      };

      recreateTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Declarative knob to force recreation of this compose instance on the next service start.";
      };

      bootTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Declarative knob to force a restart of this compose instance on the next service start.";
      };

      imageTag = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "Declarative knob to force a compose image refresh on the next service start.";
      };

      dependsOn = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Hard dependencies. Generates Requires+After. Plain names resolve to generated services in this stack; unit names like foo.service are used as-is.";
      };

      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Soft dependencies. Generates Wants+After. Plain names resolve to generated services in this stack; unit names like foo.service are used as-is.";
      };

      waitForNetwork = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to add network-online.target to Wants+After.";
      };

      envSecrets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = {};
        description = ''
          Per-compose-service file-backed environment secret injection. Maps
          compose service name to environment variable name to host secret path.
          Generates an additional compose override file that adds a generated
          env_file so the image entrypoint/cmd remain unchanged.
        '';
      };

      fileSecrets = lib.mkOption {
        type = lib.types.attrsOf fileSecretEntryType;
        default = {};
        description = ''
          File-backed secret staging for bind-mounted runtime files. Maps a
          stable secret filename to a secret entry submodule (`file` plus
          optional mode/user/group/userScope/mount/mountPath/services/readOnly).
          A bare string coerces to `{ file = <str>; }`. The helper copies each
          source to a stable path under the compose working directory before
          `podman compose up`. By default, staged secrets are bind-mounted
          read-only into `/run/secrets/<name>` in the target compose services.
        '';
      };

      exposedPorts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            port = lib.mkOption {
              type = lib.types.port;
              description = "Host port exposed by this compose instance.";
            };

            protocols = lib.mkOption {
              type = lib.types.listOf (lib.types.enum ["tcp" "udp"]);
              default = ["tcp"];
              description = "Protocols to expose for this port.";
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this port should be included when deriving firewall rules from services.podmanCompose.";
            };

            nginxHostNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Optional hostnames to serve through the repo-managed nginx reverse proxy for this port.";
            };

            upstreamProtocol = lib.mkOption {
              type = lib.types.enum [
                "http"
                "https"
              ];
              default = "http";
              description = "Protocol nginx should use when proxying to this exposed port.";
            };

            upstreamHost = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional origin host for the Host header when nginx proxies to this exposed port.";
            };

            upstreamTlsName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = "auto";
              description = "TLS SNI name for HTTPS nginx upstreams. \"auto\" derives it from upstreamHost when upstreamHost is host-only; null disables SNI.";
            };

            rootRedirect = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  path = lib.mkOption {
                    type = lib.types.str;
                    description = "Path nginx should redirect exact root requests to.";
                  };

                  status = lib.mkOption {
                    type = lib.types.enum [
                      301
                      302
                      303
                      307
                      308
                    ];
                    default = 307;
                    description = "HTTP redirect status for exact root requests.";
                  };
                };
              });
              default = null;
              description = "Optional redirect nginx should apply to exact root requests before proxying other paths.";
            };

            nginxRoutes = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  serverName = lib.mkOption {
                    type = lib.types.str;
                    description = "Hostname on the shared nginx listener that should mount this route.";
                  };

                  path = lib.mkOption {
                    type = lib.types.str;
                    description = "Path prefix on that hostname that should mount this exposed port.";
                  };

                  stripPath = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Whether nginx should strip the configured path prefix before proxying.";
                  };

                  useUpstreamCsp = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "If true, suppress nginx's global Content-Security-Policy for this route so the upstream's CSP (e.g. with per-request nonces) passes through. Other security headers remain applied.";
                  };

                  useUpstreamReferrer = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "If true, suppress nginx's global Referrer-Policy for this route so the upstream's Referrer-Policy passes through. Other security headers remain applied.";
                  };

                  useUpstreamPermissionsPolicy = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "If true, suppress nginx's global Permissions-Policy for this route so the upstream's Permissions-Policy passes through. Other security headers remain applied.";
                  };

                  upstreamProtocol = lib.mkOption {
                    type = lib.types.enum [
                      "http"
                      "https"
                    ];
                    default = "http";
                    description = "Protocol nginx should use when proxying to this route.";
                  };

                  upstreamHost = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional origin host for the Host header when nginx proxies to this route.";
                  };

                  upstreamTlsName = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = "auto";
                    description = "TLS SNI name for HTTPS nginx upstream routes. \"auto\" derives it from upstreamHost when upstreamHost is host-only; null disables SNI.";
                  };
                };
              });
              default = [];
              description = "Optional nginx routes that mount this exposed port under a path on an existing shared hostname.";
            };

            rateLimit = lib.mkOption {
              type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
              default = null;
              description = "Ingress rate-limit policy for this exposed port. When unset, the shared nginx default rate-limit profile is used.";
            };

            useUpstreamCsp = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, suppress nginx's global Content-Security-Policy for the derived root vhost so the upstream's CSP (e.g. with per-request nonces) passes through. Other security headers remain applied.";
            };

            useUpstreamReferrer = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, suppress nginx's global Referrer-Policy for the derived root vhost so the upstream's Referrer-Policy passes through. Other security headers remain applied.";
            };

            useUpstreamPermissionsPolicy = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "If true, suppress nginx's global Permissions-Policy for the derived root vhost so the upstream's Permissions-Policy passes through. Other security headers remain applied.";
            };

            cfTunnelNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Optional Cloudflare Tunnel hostnames to route to this exposed port.";
            };

            cfTunnelPort = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Optional host port Cloudflare Tunnel should target for these hostnames. Defaults to this exposed port when unset.";
            };
          };
        }));
        default = {};
        description = "Named host ports exposed by this compose instance, for example http/https/main. Intended for reuse in compose definitions and host policy like firewall rules.";
      };
    };
  });

  instanceFnType = lib.types.mkOptionType {
    name = "podman-compose-instance-function";
    description = "Function that receives derived instance context and returns an instance attrset.";
    check = builtins.isFunction;
    merge = loc: defs:
      if builtins.length defs == 1
      then (builtins.head defs).value
      else throw "services.podmanCompose.${lib.concatStringsSep "." loc}: multiple function definitions are not supported.";
  };

  stackType = lib.types.submodule ({name, ...}: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Default user for services in this stack.";
      };

      stackDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/podman-${name}";
        description = "Default stack directory root; each instance uses <stackDir>/<instance> when instance workingDir is unset.";
      };

      servicePrefix = lib.mkOption {
        type = lib.types.str;
        default = "${name}-";
        description = "Prefix for generated systemd user service names in this stack.";
      };

      nginxDefaultHost = lib.mkOption {
        type = lib.types.str;
        default = "host.containers.internal";
        description = "Default upstream host for nginx proxy vhosts derived from this stack's instances.";
      };

      instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [instanceFnType serviceType]);
        default = {};
        description = "Compose instances in this stack keyed by instance name. Each value can be an instance attrset or a function receiving { stackName; instanceName; user; uid; workDir; stackDir; podmanSocket } and returning an instance attrset. podmanSocket resolves to /run/podman/podman.sock for root stacks, otherwise /run/user/<uid>/podman/podman.sock.";
      };

      nginxProxyVhosts = lib.mkOption {
        type = lib.types.attrsOf nginxLib.proxyVhostType;
        default = {};
        readOnly = true;
        description = "Derived nginx reverse-proxy vhosts built from instance exposedPorts metadata.";
      };

      nginxRoutes = lib.mkOption {
        type = lib.types.attrsOf nginxLib.routeType;
        default = {};
        readOnly = true;
        description = "Derived nginx routes built from instance exposedPorts metadata.";
      };

      cloudflareTunnelIngress = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        description = "Derived Cloudflare Tunnel ingress built from instance exposedPorts metadata.";
      };
    };
  });

  mkResolvedService = {
    stack,
    serviceName,
    service,
  }: let
    resolvedUser =
      if service.user != null
      then service.user
      else stack.user;

    resolvedWorkingDir = service.resolvedWorkingDir;

    resolvedComposeFiles =
      if service.entryFile != null
      then
        if builtins.isList service.entryFile
        then map (file: service.runtimePaths.${file}) service.entryFile
        else [service.runtimePaths.${service.entryFile}]
      else if service.source != null
      then [service.runtimePaths."compose.yml"]
      else [];

    resolvedSystemdServiceName =
      if service.serviceName != null
      then service.serviceName
      else "${stack.servicePrefix}${serviceName}";

    resolveGeneratedServiceName = svcName: let
      svc = stack.instances.${svcName};
    in
      if svc.serviceName != null
      then svc.serviceName
      else "${stack.servicePrefix}${svcName}";

    resolveDependencyUnit = dep:
      if builtins.hasAttr dep stack.instances
      then "${resolveGeneratedServiceName dep}.service"
      else if builtins.match ".*\\.[A-Za-z0-9_-]+$" dep != null
      then dep
      else "${stack.servicePrefix}${dep}.service";

    dependsOnUnits = lib.unique (map resolveDependencyUnit service.dependsOn);
    wantsUnits = lib.unique (map resolveDependencyUnit service.wants);
    networkOnlineUnits = lib.optional service.waitForNetwork "network-online.target";

    imagePullServiceName = "${resolvedSystemdServiceName}-image-pull";
    imagePullUnit = "${imagePullServiceName}.service";
    hasImagePullUnit = service.imageTag != "0";
    entryPermsJson = entry: {
      mode = entry.mode;
      user = ownerRefToString entry.user;
      group = ownerRefToString entry.group;
      scope = entry.userScope;
    };
    helperMetadata = pkgs.writeText "podman-compose-${resolvedSystemdServiceName}.json" (
      builtins.toJSON {
        version = 3;
        serviceName = resolvedSystemdServiceName;
        workingDir = resolvedWorkingDir;
        composeArgs = service.composeArgs;
        composeFiles = resolvedComposeFiles;
        stagedDirs = map (dirName: let
          entry = service.dirs.${dirName};
        in
          {
            dst = service.dirRuntimePaths.${dirName};
          }
          // entryPermsJson entry) (builtins.attrNames service.dirs);
        stagedFiles =
          map (fileName: let
            entry = service.stagedEntries.${fileName};
          in
            {
              src = service.sourcePaths.${fileName};
              dst = service.runtimePaths.${fileName};
              dstDir = builtins.dirOf service.runtimePaths.${fileName};
              dstDirMode = "0750";
            }
            // entryPermsJson entry) (builtins.attrNames service.stagedEntries)
          ++ map (secretName: let
            entry = service.fileSecrets.${secretName};
          in
            {
              src = entry.file;
              dst = service.fileSecretRuntimePaths.${secretName};
              dstDir = builtins.dirOf service.fileSecretRuntimePaths.${secretName};
              dstDirMode = "0700";
            }
            // entryPermsJson entry) (builtins.attrNames service.fileSecrets);
        recreateOnSwitch = service.recreateOnSwitch;
        envSecretFiles = map (composeServiceName: let
          entry = service.envSecrets.${composeServiceName};
        in
          {
            dst = service.envSecretRuntimePaths.${composeServiceName};
            dstDir = builtins.dirOf service.envSecretRuntimePaths.${composeServiceName};
            entries = map (envName: {
              name = envName;
              src = entry.entries.${envName};
            }) (builtins.attrNames entry.entries);
          }
          // entryPermsJson entry) (builtins.attrNames service.envSecrets);
      }
    );
    helperEnvironment = [
      "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      "NIX_PODMAN_COMPOSE_METADATA=${helperMetadata}"
      "NIX_PODMAN_COMPOSE_SERVICE_NAME=${resolvedSystemdServiceName}"
    ];
    baseSystemdService = {
      description = "podman: ${resolvedUser}: ${serviceName}";
      after = lib.unique (
        networkOnlineUnits
        ++ dependsOnUnits
        ++ wantsUnits
        ++ lib.optional hasImagePullUnit imagePullUnit
      );
      wants = lib.unique (networkOnlineUnits ++ wantsUnits ++ lib.optional hasImagePullUnit imagePullUnit);
      wantedBy = lib.optional service.autoStart bootReadyTargetName;
      unitConfig.ConditionUser = resolvedUser;
      unitConfig.Requires = dependsOnUnits ++ lib.optional hasImagePullUnit imagePullUnit;
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        Environment = helperEnvironment;
        # Allow first start when the compose working directory doesn't exist yet.
        # ExecStart creates it before invoking podman compose.
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} start";
        ExecStop = "${helperScript} stop";
        ExecReload = "${helperScript} reload";
        ExecStopPost = "${helperScript} cleanup-files";
        KillMode = "mixed";
        Delegate = true;
        Restart = "on-failure";
      };
    };
    imagePullSystemdService = lib.optionalAttrs hasImagePullUnit {
      description = "podman: ${resolvedUser}: ${serviceName} image pull";
      after = lib.unique networkOnlineUnits;
      wants = lib.unique networkOnlineUnits;
      unitConfig.ConditionUser = resolvedUser;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment =
          helperEnvironment
          ++ [
            "PODMAN_COMPOSE_IMAGE_TAG=${service.imageTag}"
          ];
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} image-pull";
        TimeoutStartSec = 900;
      };
    };
    mergedSystemdService = lib.recursiveUpdate baseSystemdService service.serviceOverrides;
  in {
    systemdServiceName = resolvedSystemdServiceName;
    systemdUser = resolvedUser;
    systemdService = mergedSystemdService;
    auxiliarySystemdUserServices = lib.optional hasImagePullUnit {
      name = imagePullServiceName;
      value = imagePullSystemdService;
    };
    restartStamp = builtins.hashString "sha256" (builtins.toJSON {
      unit = mergedSystemdService;
      sourcePaths = service.sourcePaths;
      runtimePaths = service.runtimePaths;
      dirs = lib.mapAttrs (_: entryPermsJson) service.dirs;
      dirRuntimePaths = service.dirRuntimePaths;
      stagedEntryPerms =
        lib.mapAttrs (_: entryPermsJson) service.stagedEntries;
      fileSecrets = lib.mapAttrs (_: entry:
        {
          inherit
            (entry)
            file
            mount
            mountPath
            readOnly
            services
            ;
        }
        // entryPermsJson entry)
      service.fileSecrets;
      fileSecretRuntimePaths = service.fileSecretRuntimePaths;
      envSecrets = lib.mapAttrs (_: entry:
        {inherit (entry) entries;} // entryPermsJson entry)
      service.envSecrets;
      envSecretRuntimePaths = service.envSecretRuntimePaths;
    });
    inherit (service) autoStart imageTag recreateTag bootTag;
  };

  resolvedServices = lib.concatLists (
    lib.mapAttrsToList (
      _: stack:
        lib.mapAttrsToList (
          serviceName: service:
            mkResolvedService {
              inherit stack serviceName service;
            }
        )
        stack.instances
    )
    cfg
  );

  allExposedPorts = lib.concatLists (
    lib.mapAttrsToList (
      _: stack:
        lib.concatMap (service: lib.attrValues service.exposedPorts) (builtins.attrValues stack.instances)
    )
    cfg
  );

  firewallExposedPorts = builtins.filter (portCfg: portCfg.openFirewall or false) allExposedPorts;

  firewallPortsForProtocol = protocol:
    lib.unique (
      map (portCfg: portCfg.port) (
        builtins.filter (portCfg: builtins.elem protocol (portCfg.protocols or ["tcp"])) firewallExposedPorts
      )
    );

  generatedSystemdUserServiceNames =
    (map (service: service.systemdServiceName) resolvedServices)
    ++ lib.concatMap
    (service: map (aux: aux.name) service.auxiliarySystemdUserServices)
    resolvedServices;
  duplicateSystemdUserServiceNames = collectionsLib.duplicateValues generatedSystemdUserServiceNames;
in {
  imports = [
    ../systemd-user-manager
  ];

  options.services.podmanCompose = lib.mkOption {
    type = lib.types.attrsOf stackType;
    default = {};
    description = "Podman compose stacks. Example: services.podmanCompose.stack1.instances.web = { ... };";
    apply = stacks:
      lib.mapAttrs
      (stackName: stack: let
        applyEntryDefaults = defaults: entry: defaults // entry;
        normalizeFileEntry = entry:
          applyEntryDefaults fileEntryDefaults (
            if builtins.isPath entry
            then {source = entry;}
            else if builtins.isString entry
            then {text = entry;}
            else entry
          );
        normalizeFileSecretEntry = entry:
          applyEntryDefaults fileSecretEntryDefaults (
            if builtins.isString entry
            then {file = entry;}
            else entry
          );
        normalizeEnvSecretEntry = entry:
          envSecretEntryDefaults // {entries = entry;};
        renderEntry = serviceName: fileName: entry: let
          safeName = builtins.replaceStrings ["/" "."] ["__" "_"] fileName;
          outName = "podman-compose-${stackName}-${serviceName}-${safeName}";
        in
          if entry.source != null
          then
            pkgs.runCommandLocal outName {} ''
              set -eu
              src=${entry.source}
              ${pkgs.coreutils}/bin/cp -f "$src" "$out"
            ''
          else pkgs.writeText outName entry.text;
        expandFileEntry = dstPrefix: entry:
          if entry.source != null && builtins.isPath entry.source
          then let
            pathString = toString entry.source;
            pathName = builtins.baseNameOf pathString;
            pathParent = builtins.dirOf pathString;
            pathKind = (builtins.readDir pathParent).${pathName} or null;
          in
            if pathKind == "directory"
            then
              lib.concatMapAttrs
              (name: kind: let
                childSrc = entry.source + "/${name}";
                childDst =
                  if dstPrefix == ""
                  then name
                  else "${dstPrefix}/${name}";
                childEntry = entry // {source = childSrc;};
              in
                if kind == "directory"
                then expandFileEntry childDst childEntry
                else if kind == "regular" || kind == "symlink"
                then {"${childDst}" = childEntry;}
                else {})
              (builtins.readDir entry.source)
            else {"${dstPrefix}" = entry;}
          else {"${dstPrefix}" = entry;};
        mkGeneratedEntry = composeSource:
          fileEntryDefaults
          // {
            text =
              if builtins.isAttrs composeSource
              then lib.generators.toYAML {} composeSource
              else composeSource;
          };
      in
        stack
        // (let
          instancesWithContext =
            lib.mapAttrs
            (serviceName: serviceOrFn:
              if builtins.isFunction serviceOrFn
              then let
                resolvedUser = stack.user;
                userUid =
                  if resolvedUser == "root"
                  then "0"
                  else if builtins.hasAttr resolvedUser config.users.users && config.users.users.${resolvedUser}.uid != null
                  then toString config.users.users.${resolvedUser}.uid
                  else throw "services.podmanCompose.${stackName}: stack user '${resolvedUser}' must exist in config.users.users with a non-null uid when using function-valued instances.";
                podmanSocket =
                  if resolvedUser == "root"
                  then "/run/podman/podman.sock"
                  else "/run/user/${userUid}/podman/podman.sock";
              in
                serviceOrFn {
                  inherit stackName serviceName;
                  instanceName = serviceName;
                  user = resolvedUser;
                  uid = userUid;
                  workDir = "${stack.stackDir}/${serviceName}";
                  stackDir = stack.stackDir;
                  podmanSocket = podmanSocket;
                }
              else serviceOrFn)
            stack.instances;

          resolvedInstances =
            lib.mapAttrs
            (serviceName: service: let
              baseService = defaultService // service;
              normalizedService =
                baseService
                // {
                  dirs = lib.mapAttrs (_: applyEntryDefaults dirEntryDefaults) baseService.dirs;
                  envSecrets = lib.mapAttrs (_: normalizeEnvSecretEntry) baseService.envSecrets;
                  files = lib.mapAttrs (_: normalizeFileEntry) baseService.files;
                  fileSecrets = lib.mapAttrs (_: normalizeFileSecretEntry) baseService.fileSecrets;
                };
              useSource = normalizedService.source != null;
              hasComposeEntry = useSource || normalizedService.entryFile != null;
              sourceCompose =
                if builtins.isPath normalizedService.source
                then builtins.readFile normalizedService.source
                else normalizedService.source;
              envSecretsOverrideFileName = "__podman-env-secrets.override.yml";
              fileSecretsOverrideFileName = "__podman-file-secrets.override.yml";
              sourceDeclaredComposeServices =
                if
                  builtins.isAttrs sourceCompose
                  && builtins.hasAttr "services" sourceCompose
                  && builtins.isAttrs sourceCompose.services
                then builtins.attrNames sourceCompose.services
                else [serviceName];
              envSecretsOverride =
                if normalizedService.envSecrets == {}
                then {}
                else {
                  services =
                    lib.mapAttrs (
                      composeServiceName: _: {
                        env_file = [envSecretRuntimePaths.${composeServiceName}];
                      }
                    )
                    normalizedService.envSecrets;
                };
              mountedFileSecrets = lib.filterAttrs (_: entry: entry.mount) normalizedService.fileSecrets;
              fileSecretMountPath = secretName: entry:
                if entry.mountPath != null
                then entry.mountPath
                else "/run/secrets/${secretName}";
              fileSecretMountServices = entry:
                if entry.services != null
                then entry.services
                else sourceDeclaredComposeServices;
              fileSecretTargetServices = lib.unique (
                lib.concatMap (
                  secretName:
                    fileSecretMountServices mountedFileSecrets.${secretName}
                ) (builtins.attrNames mountedFileSecrets)
              );
              fileSecretMountsForService = composeServiceName:
                lib.concatMap (
                  secretName: let
                    entry = mountedFileSecrets.${secretName};
                  in
                    lib.optionals (builtins.elem composeServiceName (fileSecretMountServices entry)) [
                      "${fileSecretRuntimePaths.${secretName}}:${fileSecretMountPath secretName entry}${lib.optionalString entry.readOnly ":ro"}"
                    ]
                ) (builtins.attrNames mountedFileSecrets);
              fileSecretsOverride =
                if fileSecretTargetServices == []
                then {}
                else {
                  services = lib.listToAttrs (
                    map (composeServiceName: {
                      name = composeServiceName;
                      value = {
                        volumes = fileSecretMountsForService composeServiceName;
                      };
                    })
                    fileSecretTargetServices
                  );
                };
              normalizedEntryFile = let
                baseEntryFiles =
                  if normalizedService.entryFile != null
                  then
                    if builtins.isList normalizedService.entryFile
                    then normalizedService.entryFile
                    else [normalizedService.entryFile]
                  else if useSource
                  then ["compose.yml"]
                  else [];
                generatedOverrideFiles =
                  lib.optionals (envSecretsOverride != {}) [envSecretsOverrideFileName]
                  ++ lib.optionals (fileSecretsOverride != {}) [fileSecretsOverrideFileName];
              in
                if generatedOverrideFiles == []
                then normalizedService.entryFile
                else baseEntryFiles ++ generatedOverrideFiles;
              filesExpanded =
                lib.concatMapAttrs (dstPath: entry: expandFileEntry dstPath entry) normalizedService.files;
              effectiveEntries =
                (lib.optionalAttrs useSource {"compose.yml" = mkGeneratedEntry sourceCompose;})
                // filesExpanded
                // (lib.optionalAttrs (envSecretsOverride != {}) {"${envSecretsOverrideFileName}" = mkGeneratedEntry envSecretsOverride;})
                // (lib.optionalAttrs (fileSecretsOverride != {}) {"${fileSecretsOverrideFileName}" = mkGeneratedEntry fileSecretsOverride;});
              resolvedWorkingDir =
                if normalizedService.workingDir != null
                then normalizedService.workingDir
                else "${stack.stackDir}/${serviceName}";
              fileSecretRuntimePaths =
                lib.mapAttrs
                (secretName: _: "${resolvedWorkingDir}/.podman-file-secrets/${secretName}")
                normalizedService.fileSecrets;
              dirRuntimePaths =
                lib.mapAttrs
                (
                  dirName: _:
                    if dirName == ""
                    then resolvedWorkingDir
                    else "${resolvedWorkingDir}/${dirName}"
                )
                normalizedService.dirs;
              envSecretRuntimePaths =
                lib.mapAttrs
                (composeServiceName: _: "${resolvedWorkingDir}/.podman-env-secrets/${composeServiceName}.env")
                normalizedService.envSecrets;
            in
              normalizedService
              // {
                resolvedWorkingDir = resolvedWorkingDir;
                hasComposeEntry = hasComposeEntry;
                fileSecretRuntimePaths = fileSecretRuntimePaths;
                dirRuntimePaths = dirRuntimePaths;
                envSecretRuntimePaths = envSecretRuntimePaths;
                stagedEntries = effectiveEntries;
                sourcePaths = lib.mapAttrs (fileName: entry: renderEntry serviceName fileName entry) effectiveEntries;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveEntries;
                entryFile = normalizedEntryFile;
              })
            instancesWithContext;
        in {
          instances = resolvedInstances;
          nginxProxyVhosts =
            nginxLib.proxyVhostsFromInstances {
              defaultHost = stack.nginxDefaultHost;
            }
            resolvedInstances;
          nginxRoutes =
            nginxLib.routesFromInstances {
              defaultHost = stack.nginxDefaultHost;
            }
            resolvedInstances;
          cloudflareTunnelIngress = cloudflareTunnelsLib.ingressFromInstances resolvedInstances;
        }))
      stacks;
  };

  config = lib.mkIf hasStacks {
    environment.systemPackages = with pkgs; [
      podman
      podman-compose
    ];

    networking.firewall.allowedTCPPorts = firewallPortsForProtocol "tcp";
    networking.firewall.allowedUDPPorts = firewallPortsForProtocol "udp";

    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList
      (_: stack: [
        "d ${stack.stackDir} 0750 ${stack.user} ${stack.user} -"
      ])
      cfg
    );

    assertions =
      [
        {
          assertion = duplicateSystemdUserServiceNames == [];
          message = "services.podmanCompose: duplicate generated systemd.user service names: ${lib.concatStringsSep ", " duplicateSystemdUserServiceNames}";
        }
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.source != null || service.files != {};
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: set source and/or files.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.concatMap
          (serviceName:
            lib.mapAttrsToList
            (fileName: entry: {
              assertion = (entry.text != null && entry.source == null) || (entry.text == null && entry.source != null);
              message = "services.podmanCompose.${stackName}.instances.${serviceName}.files.${fileName}: set exactly one of text or source.";
            })
            stack.instances.${serviceName}.files)
          (builtins.attrNames stack.instances))
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: let
            mountedFileSecrets = lib.filterAttrs (_: entry: entry.mount) service.fileSecrets;
          in {
            assertion = mountedFileSecrets == {} || service.hasComposeEntry;
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: auto-mounted fileSecrets require source or entryFile so podman compose can include the generated override file.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.envSecrets == {} || service.hasComposeEntry;
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: envSecrets requires source or entryFile so podman compose can include the generated override file.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.concatMap
          (serviceName:
            lib.mapAttrsToList
            (composeServiceName: secretCfg: {
              assertion = secretCfg.entries != {};
              message = "services.podmanCompose.${stackName}.instances.${serviceName}.envSecrets.${composeServiceName}: set at least one environment secret.";
            })
            stack.instances.${serviceName}.envSecrets)
          (builtins.attrNames stack.instances))
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion =
              service.entryFile
              == null
              || (
                if builtins.isList service.entryFile
                then lib.all (file: builtins.hasAttr file service.runtimePaths) service.entryFile
                else builtins.hasAttr service.entryFile service.runtimePaths
              );
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: entryFile '${toString service.entryFile}' is not defined in source/files.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.concatMap
          (serviceName: let
            instance = stack.instances.${serviceName};
            checkEntry = kind: name: entry: let
              ok = entry.userScope == "host" || (isOwnerNumeric entry.user && isOwnerNumeric entry.group);
            in {
              assertion = ok;
              message = "services.podmanCompose.${stackName}.instances.${serviceName}.${kind}.${name}: userScope = \"container\" requires numeric user and group (userns has no name resolution).";
            };
          in
            lib.mapAttrsToList (name: entry: checkEntry "dirs" name entry) instance.dirs
            ++ lib.mapAttrsToList (name: entry: checkEntry "files" name entry) instance.stagedEntries
            ++ lib.mapAttrsToList (name: entry: checkEntry "fileSecrets" name entry) instance.fileSecrets
            ++ lib.mapAttrsToList (name: entry: checkEntry "envSecrets" name entry) instance.envSecrets)
          (builtins.attrNames stack.instances))
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.concatMap
          (serviceName:
            lib.mapAttrsToList
            (dirName: entry: {
              assertion = isOctalMode entry.mode && dirModeHasSearchBit entry.mode;
              message = "services.podmanCompose.${stackName}.instances.${serviceName}.dirs.${dirName}.mode must be an octal directory mode with at least one execute/search bit.";
            })
            stack.instances.${serviceName}.dirs)
          (builtins.attrNames stack.instances))
        cfg
      );

    systemd.user.services = lib.listToAttrs (
      (map
        (s: {
          name = s.systemdServiceName;
          value = s.systemdService;
        })
        resolvedServices)
      ++ lib.concatMap (s: s.auxiliarySystemdUserServices) resolvedServices
    );

    services.systemdUserManager.instances = lib.listToAttrs (map
      (s: {
        name = s.systemdServiceName;
        value = {
          user = s.systemdUser;
          unit = "${s.systemdServiceName}.service";
          autoStart = s.autoStart;
          restartTriggers = [
            s.restartStamp
            s.recreateTag
            s.bootTag
          ];
          stampPayload = {
            kind = "podman-managed-unit";
            restartStamp = s.restartStamp;
            recreateTag = s.recreateTag;
            bootTag = s.bootTag;
          };
        };
      })
      resolvedServices);
  };
}
