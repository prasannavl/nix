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

      instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [instanceFnType serviceType]);
        default = {};
        description = "Compose instances in this stack keyed by instance name. Each value can be an instance attrset or a function receiving { stackName, instanceName, user, uid, workDir, stackDir, podmanSocket } and returning an instance attrset. podmanSocket resolves to /run/podman/podman.sock for root stacks, otherwise /run/user/<uid>/podman/podman.sock.";
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
      else "${stack.stackDir}/${serviceName}";

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

    composeFileArgs = lib.concatMapStringsSep "" (composeFile: " -f ${lib.escapeShellArg composeFile}") resolvedComposeFiles;
    podmanComposeCmd = "${pkgs.podman}/bin/podman compose${composeFileArgs}";
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
        stack.instances
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
        // {
          instances = let
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
                      inherit podmanSocket;
                    }
                else serviceOrFn)
              stack.instances;
          in
            lib.mapAttrs
            (serviceName: service: let
              normalizedService =
                {
                  source = null;
                  files = {};
                  entryFile = null;
                  user = null;
                  workingDir = null;
                  serviceName = null;
                  serviceOverrides = {};
                  dependsOn = [];
                  wants = [];
                  waitForNetwork = true;
                }
                // service;
              useSource = normalizedService.source != null;
              sourceCompose =
                if builtins.isPath normalizedService.source
                then builtins.readFile normalizedService.source
                else normalizedService.source;
              filesExpanded = lib.concatMapAttrs (dstPath: value: expandFileValue dstPath value) normalizedService.files;
              effectiveFilesRaw = (lib.optionalAttrs useSource {"compose.yml" = sourceCompose;}) // filesExpanded;
              resolvedWorkingDir =
                if normalizedService.workingDir != null
                then normalizedService.workingDir
                else "${stack.stackDir}/${serviceName}";
            in
              normalizedService
              // {
                sourcePaths = lib.mapAttrs (fileName: value: renderValue serviceName fileName value) effectiveFilesRaw;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveFilesRaw;
              })
            instancesWithContext;
        })
      stacks;
  };

  config = {
    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList
      (_: stack: [
        "d ${stack.stackDir} 0750 ${stack.user} ${stack.user} -"
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
            serviceName = "systemd-user-manager-podman-${s.systemdServiceName}";
          };
        }
      )
      resolvedServices
    );
  };
}
