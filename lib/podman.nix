{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.services.podmanCompose;

  serviceType = lib.types.submodule ({...}: {
    options = {
      source = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.lines lib.types.attrs lib.types.path]);
        default = null;
        description = "Main compose source content. Attrsets are rendered to YAML; strings are copied as-is; paths are used directly.";
      };

      files = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [lib.types.lines lib.types.attrs lib.types.path]);
        default = {};
        description = "Additional files keyed by filename. Attrset values are rendered to YAML; string values are copied as-is; path values are used directly. Can override compose.yml from source.";
      };

      entryFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional compose entry filename inside workingDir. When null, podman compose default file discovery is used in workingDir.";
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
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Resolved source paths by filename.";
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
        description = "Default working directory root; each service uses <workingDir>/<service> when service workingDir is unset.";
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
    stack,
    serviceName,
    service,
  }: let
    resolvedUser =
      if service.user != null
      then service.user
      else stack.user;

    resolvedWorkingDir =
      if service.workingDir != null
      then service.workingDir
      else "${stack.workingDir}/${serviceName}";

    resolvedComposeFile =
      if service.entryFile != null
      then service.runtimePaths.${service.entryFile}
      else null;

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

    podmanComposeCmd = "${pkgs.podman}/bin/podman compose${lib.optionalString (resolvedComposeFile != null) " -f ${resolvedComposeFile}"}";
    manifestPath = "$runtime_dir/podman-compose/${resolvedSystemdServiceName}.manifest";
    linkCmdsBody = lib.concatStringsSep "\n" (
      [
        "set -eu"
        "runtime_dir=\"$XDG_RUNTIME_DIR\""
        "[ -n \"$runtime_dir\" ]"
        "${pkgs.coreutils}/bin/install -d -m 0750 ${resolvedWorkingDir}"
        "${pkgs.coreutils}/bin/install -d -m 0700 \"$runtime_dir/podman-compose\""
        "tmp_manifest=\"${manifestPath}.tmp\""
        ": > \"$tmp_manifest\""
      ]
      ++ map
      (fileName: let
        src = lib.escapeShellArg service.sourcePaths.${fileName};
        dst = lib.escapeShellArg service.runtimePaths.${fileName};
        dstDir = lib.escapeShellArg (builtins.dirOf service.runtimePaths.${fileName});
      in ''
        ${pkgs.coreutils}/bin/install -d -m 0750 ${dstDir}
        ${pkgs.coreutils}/bin/ln -sfn ${src} ${dst}
        ${pkgs.coreutils}/bin/printf '%s\n' ${dst} >> "$tmp_manifest"
      '')
      (builtins.attrNames service.sourcePaths)
      ++ [
        "${pkgs.coreutils}/bin/mv -f \"$tmp_manifest\" ${manifestPath}"
      ]
    );
    cleanupCmdBody = ''
      set -eu
      runtime_dir="$XDG_RUNTIME_DIR"
      [ -n "$runtime_dir" ]
      if [ -f ${manifestPath} ]; then
        while IFS= read -r path; do
          if [ -L "$path" ]; then
            ${pkgs.coreutils}/bin/rm -f "$path"
          fi
        done < ${manifestPath}
        ${pkgs.coreutils}/bin/rm -f ${manifestPath}
      fi
    '';
    linkScript = pkgs.writeShellScript "podman-compose-${resolvedSystemdServiceName}-link-files" linkCmdsBody;
    cleanupScript = pkgs.writeShellScript "podman-compose-${resolvedSystemdServiceName}-cleanup-files" cleanupCmdBody;

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
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
        # Allow first start when the compose working directory doesn't exist yet.
        # ExecStartPre creates it before ExecStart runs.
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${podmanComposeCmd} up -d --remove-orphans";
        ExecStop = "${podmanComposeCmd} down";
        ExecReload = "${podmanComposeCmd} up -d --remove-orphans";
        ExecStartPre = "${linkScript}";
        ExecStopPost = "${cleanupScript}";
        TimeoutStartSec = 900;
        TimeoutStopSec = 300;
      };
    };
    mergedSystemdService = lib.recursiveUpdate baseSystemdService service.serviceOverrides;
  in {
    systemdServiceName = resolvedSystemdServiceName;
    systemdUser = resolvedUser;
    systemdService = mergedSystemdService;
    restartStamp = builtins.hashString "sha256" (builtins.toJSON {
      unit = mergedSystemdService;
      sourcePaths = service.sourcePaths;
      runtimePaths = service.runtimePaths;
    });
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
        stack.services
    )
    cfg
  );
in {
  imports = [
    ./systemd-user-manager.nix
  ];

  options.services.podmanCompose = lib.mkOption {
    type = lib.types.attrsOf stackType;
    default = {};
    description = "Podman compose stacks. Example: services.podmanCompose.stack1.services.web = { ... };";
    apply = stacks:
      lib.mapAttrs
      (stackName: stack: let
        renderValue = serviceName: fileName: value: let
          safeName = builtins.replaceStrings ["/" "."] ["__" "_"] fileName;
          outName = "podman-compose-${stackName}-${serviceName}-${safeName}";
          rendered =
            if builtins.isAttrs value
            then lib.generators.toYAML {} value
            else if builtins.isPath value
            then builtins.readFile value
            else value;
        in
          if builtins.isPath value
          then builtins.toString value
          else builtins.toString (pkgs.writeText outName rendered);
      in
        stack
        // {
          services =
            lib.mapAttrs
            (serviceName: service: let
              useSource = service.source != null;
              effectiveFilesRaw = (lib.optionalAttrs useSource {"compose.yml" = service.source;}) // service.files;
              resolvedWorkingDir =
                if service.workingDir != null
                then service.workingDir
                else "${stack.workingDir}/${serviceName}";
            in
              service
              // {
                sourcePaths = lib.mapAttrs (fileName: value: renderValue serviceName fileName value) effectiveFilesRaw;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveFilesRaw;
              })
            stack.services;
        })
      stacks;
  };

  config = {
    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList
      (_: stack: [
        "d ${stack.workingDir} 0750 ${stack.user} ${stack.user} -"
      ])
      cfg
    );

    assertions =
      lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.source != null || service.files != {};
            message = "services.podmanCompose.${stackName}.services.${serviceName}: set source and/or files.";
          })
          stack.services)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.entryFile == null || builtins.hasAttr service.entryFile service.runtimePaths;
            message = "services.podmanCompose.${stackName}.services.${serviceName}: entryFile '${toString service.entryFile}' is not defined in source/files.";
          })
          stack.services)
        cfg
      );

    systemd.user.services = lib.listToAttrs (
      map (
        s: {
          name = s.systemdServiceName;
          value = s.systemdService;
        }
      )
      resolvedServices
    );

    services.systemdUserManager.bridges = lib.listToAttrs (
      map (
        s: {
          name = s.systemdServiceName;
          value = {
            user = s.systemdUser;
            unit = "${s.systemdServiceName}.service";
            restartTriggers = [s.restartStamp];
            serviceName = "systemd-user-manger-podman-${s.systemdServiceName}";
          };
        }
      )
      resolvedServices
    );
  };
}
