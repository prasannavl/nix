{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.services.podmanCompose;

  serviceType = lib.types.submodule ({...}: {
    options = {
      composeText = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Compose YAML content for this service. Mutually exclusive with composeFile.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override user for this service.";
      };

      sourceFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source compose YAML path for composeText mode. Defaults to <sourceDir>/<service>.yml.";
      };

      composeDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Target compose working directory.";
      };

      composeFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Existing compose file path used directly by podman compose. Mutually exclusive with composeText.";
      };

      serviceName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override generated systemd user service name.";
      };

      manageEtc = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to generate environment.etc entry in composeText mode. Ignored when composeFile is set.";
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Extra attributes merged into generated systemd.user.services.<name>.";
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
    };
  });

  stackType = lib.types.submodule ({name, ...}: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Default user for services in this stack.";
      };

      workingDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/podman-${name}";
        description = "Default working directory root; each service uses <workingDir>/<service> when composeDir/composeFile is unset.";
      };

      sourceDir = lib.mkOption {
        type = lib.types.str;
        default = "/etc/podman-${name}";
        description = "Default source root for compose YAML files; each service uses <sourceDir>/<service>.yml.";
      };

      servicePrefix = lib.mkOption {
        type = lib.types.str;
        default = "${name}-";
        description = "Prefix for generated systemd user service names in this stack.";
      };

      services = lib.mkOption {
        type = lib.types.attrsOf serviceType;
        default = {};
        description = "Compose services in this stack keyed by service name.";
      };
    };
  });

  mkResolvedService = {
    stackName,
    stack,
    serviceName,
    service,
  }: let
    useComposeFile = service.composeFile != null;
    useComposeText = service.composeText != null;

    resolvedUser =
      if service.user != null
      then service.user
      else stack.user;

    resolvedComposeDir =
      if service.composeDir != null
      then service.composeDir
      else if useComposeFile
      then builtins.dirOf service.composeFile
      else "${stack.workingDir}/${serviceName}";

    resolvedComposeFile =
      if useComposeFile
      then service.composeFile
      else "${resolvedComposeDir}/compose.yml";

    resolvedSourceFile =
      if service.sourceFile != null
      then service.sourceFile
      else "${stack.sourceDir}/${serviceName}.yml";

    resolvedSystemdServiceName =
      if service.serviceName != null
      then service.serviceName
      else "${stack.servicePrefix}${serviceName}";

    resolveGeneratedServiceName = svcName: let
      svc = stack.services.${svcName};
    in
      if svc.serviceName != null
      then svc.serviceName
      else "${stack.servicePrefix}${svcName}";

    resolveDependencyUnit = dep:
      if builtins.hasAttr dep stack.services
      then "${resolveGeneratedServiceName dep}.service"
      else if builtins.match ".*\\.[A-Za-z0-9_-]+$" dep != null
      then dep
      else "${stack.servicePrefix}${dep}.service";

    dependsOnUnits = lib.unique (map resolveDependencyUnit service.dependsOn);
    wantsUnits = lib.unique (map resolveDependencyUnit service.wants);
    networkOnlineUnits = lib.optional service.waitForNetwork "network-online.target";

    podmanComposeCmd = "${pkgs.podman}/bin/podman compose -f ${resolvedComposeFile}";

    etcPathMatch = builtins.match "^/etc/(.+)$" resolvedSourceFile;
    etcPath =
      if etcPathMatch != null
      then builtins.elemAt etcPathMatch 0
      else throw "services.podmanCompose.${stackName}.services.${serviceName}: sourceFile must be under /etc when manageEtc=true, got ${resolvedSourceFile}";

    baseSystemdService = {
      description = "podman: ${resolvedUser}: ${serviceName}";
      after = lib.unique (networkOnlineUnits ++ dependsOnUnits ++ wantsUnits);
      wants = lib.unique (networkOnlineUnits ++ wantsUnits);
      wantedBy = ["default.target"];
      unitConfig.ConditionUser = resolvedUser;
      unitConfig.Requires = dependsOnUnits;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Rootless Podman needs newuidmap/newgidmap NixOS wrappers.
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
        WorkingDirectory = resolvedComposeDir;
        ExecStart = "${podmanComposeCmd} up -d --remove-orphans";
        ExecStop = "${podmanComposeCmd} down";
        ExecReload = "${podmanComposeCmd} up -d --remove-orphans";
        TimeoutStartSec = 900;
        TimeoutStopSec = 300;
      };
    }
    // lib.optionalAttrs (!useComposeFile) {
      serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/install -m 0640 ${resolvedSourceFile} ${resolvedComposeFile}";
    };
  in {
    etc =
      if service.manageEtc && useComposeText
      then {
        "${etcPath}".text = service.composeText;
      }
      else {};
    systemdServiceName = resolvedSystemdServiceName;
    systemdService = lib.recursiveUpdate baseSystemdService service.serviceOverrides;
  };

  resolvedServices = lib.concatLists (
    lib.mapAttrsToList (
      stackName: stack:
        lib.mapAttrsToList (
          serviceName: service:
            mkResolvedService {
              inherit stackName stack serviceName service;
            }
        )
        stack.services
    )
    cfg
  );
in {
  options.services.podmanCompose = lib.mkOption {
    type = lib.types.attrsOf stackType;
    default = {};
    description = "Podman compose stacks. Example: services.podmanCompose.stack1.services.web = { ... };";
  };

  config = {
    assertions = lib.concatLists (lib.mapAttrsToList
      (stackName: stack:
        lib.mapAttrsToList
        (serviceName: service: {
          assertion = (service.composeText != null) != (service.composeFile != null);
          message = "services.podmanCompose.${stackName}.services.${serviceName}: set exactly one of composeText or composeFile.";
        })
        stack.services)
      cfg);

    environment.etc = lib.foldl' (acc: s: acc // s.etc) {} resolvedServices;
    systemd.user.services = lib.listToAttrs (
      map (
        s: {
          name = s.systemdServiceName;
          value = s.systemdService;
        }
      )
      resolvedServices
    );
  };
}
