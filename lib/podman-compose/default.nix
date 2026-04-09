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
    bootTag = "0";
    recreateTag = "0";
    imageTag = "0";
    dependsOn = [];
    wants = [];
    waitForNetwork = true;
    envSecrets = {};
    fileSecrets = {};
    exposedPorts = {};
  };
  bootReadyTargetName = "systemd-user-manager-ready.target";

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
        type = lib.types.attrsOf (lib.types.oneOf [lib.types.lines lib.types.attrs lib.types.path]);
        default = {};
        description = "Additional files keyed by destination path. Attrset values are rendered to YAML; string values are copied as-is; path values support both files and directories (directories are expanded recursively under the destination path). Can override compose.yml from source.";
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
        description = "Per-compose-service file-backed environment secret injection. Maps compose service name to environment variable name to host secret file path. Generates an additional compose override file that adds a generated env_file so the image entrypoint/cmd remain unchanged.";
      };

      fileSecrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "File-backed secret staging for bind-mounted runtime files. Maps a stable secret filename to a host secret file path; the helper copies each source to a stable path under the compose working directory before `podman compose up`.";
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
    helperMetadata = pkgs.writeText "podman-compose-${resolvedSystemdServiceName}.json" (
      builtins.toJSON {
        version = 1;
        serviceName = resolvedSystemdServiceName;
        workingDir = resolvedWorkingDir;
        composeArgs = service.composeArgs;
        composeFiles = resolvedComposeFiles;
        stagedFiles =
          map (fileName: {
            src = service.sourcePaths.${fileName};
            dst = service.runtimePaths.${fileName};
            dstDir = builtins.dirOf service.runtimePaths.${fileName};
          }) (builtins.attrNames service.sourcePaths)
          ++ map (secretName: {
            src = service.fileSecrets.${secretName};
            dst = service.fileSecretRuntimePaths.${secretName};
            dstDir = builtins.dirOf service.fileSecretRuntimePaths.${secretName};
          }) (builtins.attrNames service.fileSecrets);
        recreateOnSwitch = service.recreateOnSwitch;
        envSecretFiles = map (composeServiceName: {
          dst = service.envSecretRuntimePaths.${composeServiceName};
          dstDir = builtins.dirOf service.envSecretRuntimePaths.${composeServiceName};
          entries = map (envName: {
            name = envName;
            src = service.envSecrets.${composeServiceName}.${envName};
          }) (builtins.attrNames service.envSecrets.${composeServiceName});
        }) (builtins.attrNames service.envSecrets);
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
      wantedBy = [bootReadyTargetName];
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
        KillMode = "process";
        Delegate = true;
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 900;
        TimeoutStopSec = 300;
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
      fileSecrets = service.fileSecrets;
      fileSecretRuntimePaths = service.fileSecretRuntimePaths;
      envSecrets = service.envSecrets;
      envSecretRuntimePaths = service.envSecretRuntimePaths;
    });
    inherit (service) imageTag recreateTag bootTag;
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
        renderValue = serviceName: fileName: value: let
          safeName = builtins.replaceStrings ["/" "."] ["__" "_"] fileName;
          outName = "podman-compose-${stackName}-${serviceName}-${safeName}";
        in
          if builtins.isPath value
          then
            pkgs.runCommandLocal outName {} ''
              set -eu
              src=${value}
              ${pkgs.coreutils}/bin/cp -f "$src" "$out"
            ''
          else
            pkgs.writeText outName (
              if builtins.isAttrs value
              then lib.generators.toYAML {} value
              else value
            );
        expandFileValue = dstPrefix: value:
          if builtins.isPath value
          then let
            pathString = toString value;
            pathName = builtins.baseNameOf pathString;
            pathParent = builtins.dirOf pathString;
            pathKind = (builtins.readDir pathParent).${pathName};
          in
            if pathKind == "directory"
            then
              lib.concatMapAttrs
              (name: kind: let
                childSrc = value + "/${name}";
                childDst =
                  if dstPrefix == ""
                  then name
                  else "${dstPrefix}/${name}";
              in
                if kind == "directory"
                then expandFileValue childDst childSrc
                else if kind == "regular" || kind == "symlink"
                then {"${childDst}" = childSrc;}
                else {})
              (builtins.readDir value)
            else {"${dstPrefix}" = value;}
          else {"${dstPrefix}" = value;};
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
              normalizedService = defaultService // service;
              useSource = normalizedService.source != null;
              sourceCompose =
                if builtins.isPath normalizedService.source
                then builtins.readFile normalizedService.source
                else normalizedService.source;
              envSecretsOverrideFileName = "__podman-env-secrets.override.yml";
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
              in
                if envSecretsOverride == {}
                then normalizedService.entryFile
                else baseEntryFiles ++ [envSecretsOverrideFileName];
              filesExpanded =
                lib.concatMapAttrs (dstPath: value: expandFileValue dstPath value) normalizedService.files;
              effectiveFilesRaw =
                (lib.optionalAttrs useSource {"compose.yml" = sourceCompose;})
                // filesExpanded
                // (lib.optionalAttrs (envSecretsOverride != {}) {"${envSecretsOverrideFileName}" = envSecretsOverride;});
              resolvedWorkingDir =
                if normalizedService.workingDir != null
                then normalizedService.workingDir
                else "${stack.stackDir}/${serviceName}";
              fileSecretRuntimePaths =
                lib.mapAttrs
                (secretName: _: "${resolvedWorkingDir}/.podman-file-secrets/${secretName}")
                normalizedService.fileSecrets;
              envSecretRuntimePaths =
                lib.mapAttrs
                (composeServiceName: _: "${resolvedWorkingDir}/.podman-env-secrets/${composeServiceName}.env")
                normalizedService.envSecrets;
            in
              normalizedService
              // {
                resolvedWorkingDir = resolvedWorkingDir;
                fileSecretRuntimePaths = fileSecretRuntimePaths;
                envSecretRuntimePaths = envSecretRuntimePaths;
                sourcePaths = lib.mapAttrs (fileName: value: renderValue serviceName fileName value) effectiveFilesRaw;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveFilesRaw;
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
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.envSecrets == {} || service.source != null || service.entryFile != null;
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
              assertion = secretCfg != {};
              message = "services.podmanCompose.${stackName}.instances.${serviceName}.envSecrets.${composeServiceName}: set at least one secret file.";
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
