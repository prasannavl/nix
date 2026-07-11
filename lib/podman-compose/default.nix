{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.services.podman-compose;
  hasStacks = cfg != {};
  podmanHelperPath = "/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
  flakeUtils = import ../flake/utils.nix {lib = lib;};
  exposedPortsLib = import ../services/exposed-ports {inherit lib;};
  nginxLib = import ../services/nginx {inherit lib;};
  tunnelsLib = import ../services/tunnels {inherit lib;};
  secretFileSourceHash = file: let
    fileString = toString file;
  in
    if lib.hasPrefix (builtins.storeDir + "/") fileString
    then builtins.hashString "sha256" (builtins.unsafeDiscardStringContext fileString)
    else if builtins.pathExists file
    then builtins.hashFile "sha256" file
    else null;
  fileContentSourceHash = file:
    if builtins.pathExists file
    then builtins.hashFile "sha256" file
    else null;
  sourceHashFromInputs = inputs: let
    inputHashes = builtins.filter (hash: hash != null) (map fileContentSourceHash inputs);
  in
    if inputHashes == []
    then null
    else builtins.hashString "sha256" (builtins.toJSON inputHashes);
  ageSecretSourceHashesByRuntimePath = lib.mapAttrs' (
    name: secret:
      lib.nameValuePair
      (toString (secret.path or "/run/agenix/${name}"))
      (
        if (secret ? file) && secret.file != null
        then fileContentSourceHash secret.file
        else null
      )
  ) (config.age.secrets or {});
  secretSourceHash = file:
    ageSecretSourceHashesByRuntimePath.${
      toString file
    }
    or (
      secretFileSourceHash file
    );
  serviceDefaults = {
    source = null;
    files = {};
    entryFile = null;
    user = null;
    workingDir = null;
    serviceName = null;
    serviceOverrides = {};
    composeArgs = [];
    preStart = [];
    postStart = [];
    preStop = [];
    reload = {
      method = "restart";
      signal = "HUP";
      services = [];
      trigger = {
        dirs = [];
        externalFiles = [];
      };
    };
    recreate = {
      trigger = {
        files = [];
      };
    };
    subnet = null;
    state = "running";
    reconcilePolicy = "inherit";
    removalPolicy = "inherit";
    adopt = false;
    autoStart = null;
    longRunning = true;
    timeoutReadySeconds = null;
    startStateStallSeconds = null;
    bootTag = "0";
    reloadTag = "0";
    recreateTag = "0";
    imageTag = "0";
    dependsOn = [];
    wants = [];
    waitForNetwork = true;
    envSecrets = {};
    fileSecrets = {};
    trustedCa = false;
    trustedCaCertificates = {};
    dirs = {};
    exposedPorts = {};
  };
  stackDefaultTimeoutReadySeconds = 120;
  defaultComposeEntryFiles = [
    "compose.yml"
    "compose.yaml"
    "docker-compose.yml"
    "docker-compose.yaml"
  ];
  generatedRuntimeDirName = ".podman-compose";
  envSecretsRuntimeDirName = "${generatedRuntimeDirName}/env-secrets";
  fileSecretsRuntimeDirName = "${generatedRuntimeDirName}/file-secrets";
  envSecretsOverrideFileName = "__podman-env-secrets.override.yml";
  fileSecretsOverrideFileName = "__podman-file-secrets.override.yml";
  explicitSystemdUnitPattern = ".*\\.(service|target|socket|timer|path|mount)$";
  composeServicesFromText = text: let
    lines = lib.splitString "\n" text;
    serviceLine = line:
      builtins.match "[[:space:]][[:space:]]([A-Za-z0-9_.-]+):[[:space:]]*(#.*)?" line;
    step = state: line: let
      isBlank = builtins.match "[[:space:]]*" line != null;
      startsServices = builtins.match "services:[[:space:]]*(#.*)?" line != null;
      startsTopLevel = builtins.match "[^[:space:]].*" line != null;
      match = serviceLine line;
    in
      if ! state.inServices
      then state // {inServices = startsServices;}
      else if isBlank
      then state
      else if startsTopLevel
      then state // {inServices = startsServices;}
      else if match != null
      then state // {services = state.services ++ [(builtins.elemAt match 0)];}
      else state;
    parsed =
      builtins.foldl' step {
        inServices = false;
        services = [];
      }
      lines;
  in
    lib.unique parsed.services;

  composeImagesFromText = text:
    lib.unique (
      lib.concatMap (
        line: let
          match = builtins.match "[[:space:]]*image:[[:space:]]*['\"]?([^'\"#[:space:]]+)['\"]?.*" line;
        in
          lib.optional (match != null) (builtins.head match)
      ) (lib.splitString "\n" text)
    );

  ownerRefType = lib.types.either lib.types.str lib.types.int;
  modeOptionType = lib.types.nullOr lib.types.str;
  scopeType = lib.types.enum ["host" "container"];
  ownerEntryDefaults = mode: {
    mode = mode;
    user = null;
    group = null;
    scope = "host";
  };
  dirEntryDefaults =
    ownerEntryDefaults "0750"
    // {
      once = null;
    };
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
  trustedCaCertificateEntryDefaults =
    ownerEntryDefaults "0444"
    // {
      mountPath = null;
      readOnly = true;
      services = null;
      envVars = [
        "SSL_CERT_FILE"
        "REQUESTS_CA_BUNDLE"
        "NODE_EXTRA_CA_CERTS"
      ];
      sourceHashInputs = [];
      sourceHash = null;
      sourceHashFile = null;
    };
  trustedCaDefaultEntryDefaults =
    trustedCaCertificateEntryDefaults
    // {
      name = null;
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
    scope = lib.mkOption {
      type = scopeType;
      default = (ownerEntryDefaults modeDefault).scope;
      description = "Whether mode/user/group refer to host identities or to identities inside the container user namespace. Container scope requires numeric user/group when an owner is set and applies chmod/chown via `podman unshare`.";
    };
  };
  dirEntryOptions =
    ownerOptions {
      modeDefault = dirEntryDefaults.mode;
      modeDescription = "Octal mode string applied to the staged directory.";
      userDescription = "Owner for the staged directory. Numeric uid or name. When null, unchanged.";
      groupDescription = "Group for the staged directory. Numeric gid or name. When null, unchanged.";
    }
    // {
      once = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = dirEntryDefaults.once;
        description = "When true, create and initialize the directory only when missing; existing directories are preserved. When false, reconcile mode and ownership on every helper run. Null selects the automatic default.";
      };
    };
  dirEntryType = lib.types.submodule {options = dirEntryOptions;};
  reloadType = lib.types.submodule {
    options = {
      method = lib.mkOption {
        type = lib.types.enum ["restart" "signal"];
        default = serviceDefaults.reload.method;
        description = "How `systemctl --user reload` should apply the compose instance. `restart` is the safe fallback; `signal` is opt-in for services that can reload directory-mounted config.";
      };

      signal = lib.mkOption {
        type = lib.types.str;
        default = serviceDefaults.reload.signal;
        description = "Signal passed to `podman compose kill --signal` when reload.method is `signal`.";
      };

      services = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.reload.services;
        description = "Compose service names to signal when reload.method is `signal`.";
      };

      trigger = lib.mkOption {
        type = lib.types.submodule {
          options = {
            dirs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = serviceDefaults.reload.trigger.dirs;
              description = "Directory-mounted runtime paths whose changes are safe to handle with native reload. Entries must refer to declared directory sources or dirs.";
            };

            externalFiles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = serviceDefaults.reload.trigger.externalFiles;
              description = "Explicit staged files outside container mounts whose changes may trigger native reload. Rejected when the same file is detected as a single-file bind mount. Compose-consumed files such as .env do not update container env or interpolation until restart/recreate.";
            };
          };
        };
        default = serviceDefaults.reload.trigger;
        description = "Paths that may be handled by native reload instead of restart through systemd user-service reload triggers.";
      };
    };
  };
  recreateType = lib.types.submodule {
    options = {
      trigger = lib.mkOption {
        type = lib.types.submodule {
          options = {
            files = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = serviceDefaults.recreate.trigger.files;
              description = "Explicit staged files whose changes require container recreation. Automatically detected exact single-file bind mounts are added to this effective list.";
            };
          };
        };
        default = serviceDefaults.recreate.trigger;
        description = "Paths that require `podman compose up --force-recreate` instead of reload or restart.";
      };
    };
  };

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

  trustedCaCertificateEntryOptions =
    {
      file = lib.mkOption {
        type = lib.types.either lib.types.path lib.types.str;
        description = "Host path to the CA certificate file to stage and mount.";
      };
    }
    // (ownerOptions {
      modeDefault = trustedCaCertificateEntryDefaults.mode;
      modeDescription = "Octal mode string applied to the staged CA certificate.";
    })
    // {
      mountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = trustedCaCertificateEntryDefaults.mountPath;
        description = "In-container CA certificate path. When null, defaults to `/run/secrets/<name>`.";
      };
      services = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = trustedCaCertificateEntryDefaults.services;
        description = "Compose services that should receive the CA certificate mount and environment. When null, resolves to every service declared in an attrs-shaped `source`, otherwise falls back to a single service named after the instance.";
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = trustedCaCertificateEntryDefaults.readOnly;
        description = "Whether the CA certificate mount should be read-only (`:ro`).";
      };
      envVars = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = trustedCaCertificateEntryDefaults.envVars;
        description = "Environment variables set to the CA certificate mount path for each target compose service. Use an empty list for applications with explicit CA-file flags.";
      };
      sourceHashInputs = lib.mkOption {
        type = lib.types.listOf (lib.types.either lib.types.path lib.types.str);
        default = trustedCaCertificateEntryDefaults.sourceHashInputs;
        description = "Optional Nix-visible files whose contents should drive restart detection for this CA entry.";
      };
      sourceHashFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = trustedCaCertificateEntryDefaults.sourceHashFile;
        description = "Optional Nix source file to hash for restart detection when `file` is a stable host runtime path.";
      };
      sourceHash = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = trustedCaCertificateEntryDefaults.sourceHash;
        description = "Optional explicit source hash for restart detection when `sourceHashFile` would require a generated store path.";
      };
    };
  trustedCaCertificateEntrySubmoduleType = lib.types.submodule {options = trustedCaCertificateEntryOptions;};
  trustedCaCertificateEntryType =
    lib.types.coercedTo
    (lib.types.either lib.types.path lib.types.str)
    (v: {file = v;})
    trustedCaCertificateEntrySubmoduleType;
  trustedCaDefaultEntryOptions =
    {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = trustedCaDefaultEntryDefaults.name;
        description = "Secret filename used when this CA default is injected. When null, the default key is used.";
      };
    }
    // trustedCaCertificateEntryOptions;
  trustedCaDefaultEntrySubmoduleType = lib.types.submodule {options = trustedCaDefaultEntryOptions;};
  trustedCaDefaultEntryType =
    lib.types.coercedTo
    (lib.types.either lib.types.path lib.types.str)
    (v: {file = v;})
    trustedCaDefaultEntrySubmoduleType;
  trustedCaInjectionType = lib.types.oneOf [
    lib.types.bool
    (lib.types.listOf (lib.types.either lib.types.str lib.types.attrs))
    lib.types.attrs
  ];
  podmanReconcilePolicyType = lib.types.enum [
    "inherit"
    "auto"
    "restart"
    "recreate"
  ];
  podmanRemovalPolicyType = lib.types.enum [
    "inherit"
    "keep"
    "stop"
    "delete"
    "delete-all"
  ];

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
  isReservedGeneratedPath = path:
    path
    == generatedRuntimeDirName
    || lib.hasPrefix "${generatedRuntimeDirName}/" path
    || path == envSecretsOverrideFileName
    || path == fileSecretsOverrideFileName;
  pathMatchesDir = dirName: fileName:
    fileName == dirName || lib.hasPrefix "${dirName}/" fileName;
  stackTmpfilesGroup = stack:
    if builtins.hasAttr stack.user config.users.users && config.users.users.${stack.user}.group != null
    then config.users.users.${stack.user}.group
    else "-";

  tests = import ./tests {inherit pkgs;};
  helperPackage =
    (pkgs.writeShellApplication {
      name = "podman-compose-helper";
      excludeShellChecks = ["SC1091"];
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.jq
        pkgs.podman
        pkgs.procps
        pkgs.systemd
        pkgs.util-linux
      ];
      text = ''
        export NIX_PODMAN_COMPOSE_HELPER_SELF="$0"
        export NIX_PODMAN_COMPOSE_HELPER_TOPLEVEL=1
        source ${./helper.sh}
        main "$@"
      '';
    })
    .overrideAttrs (old: let
      oldPassthru = old.passthru or {};
    in {
      passthru =
        oldPassthru
        // {
          tests = (oldPassthru.tests or {}) // tests;
        };
    });
  helperScript = "${helperPackage}/bin/podman-compose-helper";

  serviceType = lib.types.submodule (_: {
    options = {
      source = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.lines lib.types.attrs lib.types.path]);
        default = serviceDefaults.source;
        description = "Main compose source content. Attrsets are rendered to YAML; strings are copied as-is; paths are used directly.";
      };

      files = lib.mkOption {
        type = lib.types.attrsOf fileEntryType;
        default = serviceDefaults.files;
        description = ''
          Additional files keyed by destination path. Each value is a file entry
          submodule with text/source plus optional mode/user/group/scope.
          String and path shorthands coerce to `{ text = ...; }` or
          `{ source = ...; }`. The default `mode = "none"` preserves the copied
          source mode. Path sources that point to a directory expand recursively
          under the destination path, with each expanded child inheriting the
          parent's permission fields.
        '';
      };

      dirs = lib.mkOption {
        type = lib.types.attrsOf dirEntryType;
        default = serviceDefaults.dirs;
        description = ''
          Managed staged directories keyed by destination path. Relative paths
          are resolved under the compose working directory; absolute paths are
          managed directly on the host. Each entry carries mode/user/group/scope,
          plus `once` for create-only handling of persistent data dirs.
          Managed entries are finalized after file staging so directory bind
          mounts can avoid world traversal bits. The helper runs as the stack
          user, so absolute path parents must already exist and be
          searchable/writable by that user.
        '';
      };

      entryFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.str (lib.types.listOf lib.types.str)]);
        default = serviceDefaults.entryFile;
        description = "Optional compose entry filename(s) inside workingDir. Set a string for one file or a list for ordered repeated `-f` arguments. When null and source is set, `compose.yml` is used. When null for files-only stacks, staged default compose filenames are derived automatically.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = serviceDefaults.user;
        description = "Override user for this service.";
      };

      workingDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = serviceDefaults.workingDir;
        description = "Override working directory for podman compose project context.";
      };

      sourcePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        readOnly = true;
        internal = true;
        description = "Resolved source paths by filename.";
      };

      pullSourcePaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        readOnly = true;
        internal = true;
        description = "Store-backed source paths by filename for pre-activation image pulls.";
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
        default = serviceDefaults.serviceName;
        description = "Override generated systemd user service name.";
      };

      serviceOverrides = lib.mkOption {
        type = lib.types.attrs;
        default = serviceDefaults.serviceOverrides;
        description = "Extra attributes merged into generated systemd.user.services.<name>.";
      };

      subnet = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = serviceDefaults.subnet;
        description = "Optional default-network subnet used by this compose instance. This option is the module-level source of truth for subnet collision checks; inline compose network IPAM is not parsed.";
      };

      composeArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.composeArgs;
        description = "Additional arguments passed to every `podman compose` invocation for this instance, before compose-file flags and the subcommand.";
      };

      preStart = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.preStart;
        description = "Commands to run inside the compose helper after runtime dirs, files, and secrets are staged, and before `podman compose up`.";
      };

      postStart = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.postStart;
        description = "Commands to run inside the compose helper after `podman compose up` and helper start verification succeeds. Prefix a command with `-` to ignore failure.";
      };

      preStop = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.preStop;
        description = "Commands to run inside the compose helper before applying the compose stop policy. Prefix a command with `-` to ignore failure.";
      };

      reload = lib.mkOption {
        type = reloadType;
        default = serviceDefaults.reload;
        description = "Reload policy for this compose instance. Restart is the default; native signal reload is opt-in and only supports directory-mounted change sets.";
      };

      recreate = lib.mkOption {
        type = recreateType;
        default = serviceDefaults.recreate;
        description = "Recreate policy for staged files whose changes cannot be safely consumed by native reload or restart.";
      };

      state = lib.mkOption {
        type = lib.types.enum ["running" "stopped"];
        default = serviceDefaults.state;
        description = "Desired runtime state for this compose instance.";
      };

      reconcilePolicy = lib.mkOption {
        type = podmanReconcilePolicyType;
        default = serviceDefaults.reconcilePolicy;
        description = ''
          Drift-action policy for this compose instance. `inherit` uses the
          stack default. `auto` uses smart reload/restart/recreate
          classification; `restart` restarts for reload/restart-class drift and
          recreate-class drift; `recreate` force-recreates for restart-class or
          recreate-class drift.
        '';
      };

      removalPolicy = lib.mkOption {
        type = podmanRemovalPolicyType;
        default = serviceDefaults.removalPolicy;
        description = ''
          What to do when this compose instance is removed from the declaration.
          `inherit` uses the stack default. `keep` leaves the old workload
          alone for manual takeover; `stop` stops containers without removing
          compose objects; `delete` runs compose down and cleans generated
          runtime files; `delete-all` also asks compose to remove volumes and
          deletes managed staged dirs under the compose working directory.
        '';
      };

      adopt = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.adopt;
        description = ''
          Allow this declaration to initialize or replace missing or mismatched
          helper identity state in the compose working directory. Normal
          operation should leave this false; set it for one deploy when
          deliberately taking over an existing working directory. Adoption
          force-recreates containers so the adopted runtime starts from the
          declared compose shape.
        '';
      };

      autoStart = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = serviceDefaults.autoStart;
        description = "Whether this compose instance should be auto-started by the generated native user targets during deploy and boot-ready startup. When null, inherit the stack default.";
      };

      longRunning = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.longRunning;
        description = "Whether this compose instance is expected to keep at least one container running. When false, all containers exiting cleanly is service success.";
      };

      timeoutReadySeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = serviceDefaults.timeoutReadySeconds;
        description = "Seconds native user-service convergence should wait for this compose unit to become ready. When null, inherit the stack default.";
      };

      startStateStallSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = serviceDefaults.startStateStallSeconds;
        description = "Optional helper start guard for how long containers may remain non-running during `podman compose up` before the helper terminates the attempt. Leave null for the helper default.";
      };

      recreateTag = lib.mkOption {
        type = lib.types.str;
        default = serviceDefaults.recreateTag;
        description = "Declarative knob to restart this compose instance and force container recreation with `podman compose up --force-recreate`. Value \"0\" disables the trigger.";
      };

      bootTag = lib.mkOption {
        type = lib.types.str;
        default = serviceDefaults.bootTag;
        description = "Declarative knob to force a restart of this compose instance on the next service start.";
      };

      reloadTag = lib.mkOption {
        type = lib.types.str;
        default = serviceDefaults.reloadTag;
        description = "Declarative knob to reload this compose instance through native systemd user service reloadTriggers when native reload is enabled.";
      };

      imageTag = lib.mkOption {
        type = lib.types.str;
        default = serviceDefaults.imageTag;
        description = "Declarative knob to enable a compose image refresh unit before this instance starts. Pair with bootTag or recreateTag when already-running containers must be restarted after the pull.";
      };

      dependsOn = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.dependsOn;
        description = "Hard dependencies. Generates Requires+After. Plain names resolve to generated services in this stack; unit names like foo.service are used as-is.";
      };

      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = serviceDefaults.wants;
        description = "Soft dependencies. Generates Wants+After. Plain names resolve to generated services in this stack; unit names like foo.service are used as-is.";
      };

      waitForNetwork = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.waitForNetwork;
        description = "Whether to add network-online.target to Wants+After.";
      };

      envSecrets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = serviceDefaults.envSecrets;
        description = ''
          Per-compose-service file-backed environment secret injection. Maps
          compose service name to environment variable name to host secret path.
          Generates an additional compose override file that adds a generated
          env_file so the image entrypoint/cmd remain unchanged.
        '';
      };

      fileSecrets = lib.mkOption {
        type = lib.types.attrsOf fileSecretEntryType;
        default = serviceDefaults.fileSecrets;
        description = ''
          File-backed secret staging for bind-mounted runtime files. Maps a
          stable secret filename to a secret entry submodule (`file` plus
          optional mode/user/group/scope/mount/mountPath/services/readOnly).
          A bare string coerces to `{ file = <str>; }`. The helper copies each
          source to a stable path under the compose working directory before
          `podman compose up`. By default, staged secrets are bind-mounted
          read-only into `/run/secrets/<name>` in the target compose services.
        '';
      };

      trustedCaCertificates = lib.mkOption {
        type = lib.types.attrsOf trustedCaCertificateEntryType;
        default = serviceDefaults.trustedCaCertificates;
        description = ''
          Public CA certificates to stage, bind-mount, and optionally expose
          through common runtime trust environment variables. This is for
          non-secret trust anchors used by containerized applications; keep
          app-specific CA flags in the compose source when an application
          requires them.
        '';
      };

      trustedCa = lib.mkOption {
        type = trustedCaInjectionType;
        default = serviceDefaults.trustedCa;
        description = ''
          Convenience injection for stack-level trusted CA material. Set true
          to inject the public-root CA bundle into all compose services in
          this instance, set a list of compose service names to scope that
          bundle, set an attrset to override fields such as `services`,
          `envVars`, `name`, `mountPath`, or `publicRoots`, or set a
          list of attrsets when a service needs multiple CA files. Leave
          `publicRoots = true` for process-wide trust environment
          variables, and set it to false for app-native CA-file options that
          must receive only the stack CA.
          `trustedCaCertificates` remains the low-level escape hatch.
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
              description = "Whether this port should be included when deriving firewall rules from services.podman-compose.";
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
                "tcp"
                "udp"
              ];
              default = "http";
              description = "Protocol nginx should use when proxying to this exposed port. http/https render an HTTP proxy; tcp/udp render a stream proxy.";
            };

            upstreams = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = "Optional explicit upstream host:port targets for nginx proxying. When unset, nginx derives a local upstream from the exposed port.";
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

                  upstreamCaCertificate = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "CA bundle nginx should use to verify this HTTPS upstream route. When null, upstream certificate verification is not enabled by the nginx renderer.";
                  };

                  location = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional full nginx location match expression, such as '= /api/upload' or '~ ^/api/.*/upload$'. When set, path is still used for route-local rewrite and cookie path defaults.";
                  };

                  proxyBufferSize = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx proxy_buffer_size override for this route when upstream response headers are larger than nginx's default buffer.";
                  };

                  proxyBuffering = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Optional nginx proxy_buffering override for streaming upstream responses.";
                  };

                  proxyReadTimeout = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
                  };

                  proxySendTimeout = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
                  };

                  proxyRequestBuffering = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Optional nginx proxy_request_buffering override for streaming large request bodies to the upstream.";
                  };

                  clientMaxBodySize = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx client_max_body_size override for uploads to this route.";
                  };

                  rateLimit = lib.mkOption {
                    type = lib.types.nullOr exposedPortsLib.rateLimitProfileType;
                    default = null;
                    description = "Optional ingress rate-limit policy override for this route. When unset, the parent exposed port policy is used.";
                  };

                  proxyCookiePath = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
                  };

                  proxyRedirects = lib.mkOption {
                    type = lib.types.listOf (lib.types.submodule {
                      options = {
                        from = lib.mkOption {
                          type = lib.types.str;
                          description = "Upstream Location value or nginx proxy_redirect pattern to rewrite.";
                        };

                        to = lib.mkOption {
                          type = lib.types.str;
                          description = "Replacement Location value for nginx proxy_redirect.";
                        };
                      };
                    });
                    default = [];
                    description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
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

            proxyBufferSize = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx proxy_buffer_size override for this exposed port when upstream response headers are larger than nginx's default buffer.";
            };

            proxyBuffering = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Optional nginx proxy_buffering override for streaming upstream responses.";
            };

            proxyReadTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx proxy_read_timeout override for long-running upstream responses.";
            };

            proxySendTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx proxy_send_timeout override for long-running upstream requests.";
            };

            proxyConnectTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx stream proxy_connect_timeout override for TCP/UDP exposed ports.";
            };

            proxyTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx stream proxy_timeout override for TCP/UDP exposed ports.";
            };

            upstreamCaCertificate = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "CA bundle nginx should use to verify this HTTPS upstream. When null, upstream certificate verification is not enabled by the nginx renderer.";
            };

            clientMaxBodySize = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional nginx client_max_body_size override for uploads to this exposed port.";
            };

            proxyCookiePath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional replacement path for nginx proxy_cookie_path. Defaults to the served route prefix.";
            };

            proxyRedirects = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  from = lib.mkOption {
                    type = lib.types.str;
                    description = "Upstream Location value or nginx proxy_redirect pattern to rewrite.";
                  };

                  to = lib.mkOption {
                    type = lib.types.str;
                    description = "Replacement Location value for nginx proxy_redirect.";
                  };
                };
              });
              default = [];
              description = "Additional nginx proxy_redirect rewrites to apply before the default path-preserving redirect rewrite.";
            };

            tunnels = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  kind = lib.mkOption {
                    type = lib.types.enum tunnelsLib.tunnelKinds;
                    description = "Tunnel transport kind that should publish this exposed port.";
                  };

                  hostNames = lib.mkOption {
                    type = lib.types.nonEmptyListOf lib.types.str;
                    description = "Public hostnames or stable endpoint names published through this tunnel transport.";
                  };

                  name = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional stable logical tunnel endpoint name. Defaults to the first hostName.";
                  };

                  targetPort = lib.mkOption {
                    type = lib.types.nullOr lib.types.port;
                    default = null;
                    description = "Optional host port this tunnel should target. Defaults to this exposed port.";
                  };

                  service = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional rendered tunnel service target. Defaults to a protocol-derived localhost target.";
                  };

                  remotePort = lib.mkOption {
                    type = lib.types.nullOr lib.types.port;
                    default = null;
                    description = "Optional public bind port for tunnel kinds, such as rathole, that expose numbered remote ports instead of hostname ingress.";
                  };
                };
              });
              default = [];
              description = ''
                Provider-neutral tunnel publications for this exposed port.
              '';
            };
          };
        }));
        default = serviceDefaults.exposedPorts;
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
      else throw "services.podman-compose.${lib.concatStringsSep "." loc}: multiple function definitions are not supported.";
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

      timeoutReadySeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = stackDefaultTimeoutReadySeconds;
        description = "Default readiness timeout, in seconds, for compose instances in this stack. Instances can override this with their own timeoutReadySeconds.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Default auto-start behavior for compose instances in this stack. Instances can override this with their own autoStart.";
      };

      reconcilePolicy = lib.mkOption {
        type = lib.types.enum ["auto" "restart" "recreate"];
        default = "auto";
        description = ''
          Default drift-action policy for compose instances in this stack.
          `auto` uses smart reload/restart/recreate classification; `restart`
          restarts for reload/restart-class drift and recreate-class drift;
          `recreate` force-recreates for restart-class or recreate-class drift.
        '';
      };

      removalPolicy = lib.mkOption {
        type = lib.types.enum ["keep" "stop" "delete" "delete-all"];
        default = "delete";
        description = ''
          Default removal behavior for compose instances in this stack.
          Instances can override this or use `inherit` to take this value.
        '';
      };

      trustedCaDefaults = lib.mkOption {
        type = lib.types.submodule {
          options = {
            ca = lib.mkOption {
              type = lib.types.nullOr trustedCaDefaultEntryType;
              default = null;
              description = "CA entry containing only the stack CA.";
            };
            caBundle = lib.mkOption {
              type = lib.types.nullOr trustedCaDefaultEntryType;
              default = null;
              description = "CA entry containing public roots plus the stack CA.";
            };
          };
        };
        default = {};
        description = ''
          Default trusted CA entries that instances can inject with `trustedCa`.
          `ca` is only the stack CA; `caBundle` is public roots plus the stack
          CA.
        '';
      };

      instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [instanceFnType serviceType]);
        default = {};
        description = "Compose instances in this stack keyed by instance name. Each value can be an instance attrset or a function receiving { stackName; instanceName; user; uid; workDir; stackDir; podmanSocket } and returning an instance attrset. podmanSocket resolves to /run/podman/podman.sock for root stacks, otherwise /run/user/<uid>/podman/podman.sock.";
      };

      nginx-proxy-vhosts = lib.mkOption {
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

      tunnelIngress = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = {};
        readOnly = true;
        description = "Derived tunnel ingress targets keyed by transport kind.";
      };

      tunnelEndpoints = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        readOnly = true;
        description = "Provider-neutral tunnel endpoint metadata derived from instance exposedPorts.";
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

    readyTargetNameForServiceName = svcName: "${resolveGeneratedServiceName svcName}-ready.target";
    resolveDependencyUnit = dep:
      if builtins.hasAttr dep stack.instances
      then readyTargetNameForServiceName dep
      else if builtins.match explicitSystemdUnitPattern dep != null
      then dep
      else "${stack.servicePrefix}${dep}-ready.target";

    dependsOnUnits = lib.unique (map resolveDependencyUnit service.dependsOn);
    wantsUnits = lib.unique (map resolveDependencyUnit service.wants);
    networkOnlineUnits = lib.optional service.waitForNetwork "network-online.target";

    conditionUserConfig = {
      ConditionUser = resolvedUser;
    };
    serviceAutoStarts = service.state == "running" && service.autoStart;
    userManagedTargetName = managedTargetNameForUser resolvedUser;
    userManagedReadyTargetName = managedReadyTargetNameForUser resolvedUser;
    readyTargetName = "${resolvedSystemdServiceName}-ready";
    stageServiceName = "${resolvedSystemdServiceName}-stage";
    stageUnit = "${stageServiceName}.service";
    bootstrapServiceName = "${resolvedSystemdServiceName}-bootstrap";
    bootstrapUnit = "${bootstrapServiceName}.service";
    hasBootstrapUnit = service.preStart != [];
    reconcileServiceName = "${resolvedSystemdServiceName}-reconcile";
    reconcileUnit = "${reconcileServiceName}.service";
    hasReconcileUnit = service.postStart != [];
    verifyServiceName = "${resolvedSystemdServiceName}-verify";
    verifyUnit = "${verifyServiceName}.service";
    imagePullServiceName = "${resolvedSystemdServiceName}-image-pull";
    imagePullUnit = "${imagePullServiceName}.service";
    hasImagePullUnit = service.imageTag != "0";
    rootlessIdmapMigrateUnit =
      lib.optional (resolvedUser != "root") "${rootlessIdmapMigrateUserServiceNameForUser resolvedUser}.service";
    resolvedPullComposeFiles = map (file: service.pullSourcePaths.${file}) service.pullEntryFiles;
    nativeReloadEnabled = service.reload.method == "signal";
    reloadExternalFileEntries =
      if nativeReloadEnabled
      then
        lib.filterAttrs
        (fileName: _: builtins.elem fileName service.reload.trigger.externalFiles)
        service.stagedEntries
      else {};
    reloadStagedEntries =
      if nativeReloadEnabled
      then
        reloadExternalFileEntries
        // lib.filterAttrs
        (
          fileName: _:
            builtins.any
            (dirName: pathMatchesDir dirName fileName)
            service.reload.trigger.dirs
        )
        service.stagedEntries
      else {};
    isReloadTriggerDir = dirName:
      builtins.elem dirName service.reload.trigger.dirs;
    restartDirs =
      lib.filterAttrs
      (dirName: _: !isReloadTriggerDir dirName)
      service.dirs;
    restartDirRuntimePaths =
      lib.filterAttrs
      (dirName: _: !isReloadTriggerDir dirName)
      service.dirRuntimePaths;
    restartStagedEntries =
      lib.filterAttrs
      (fileName: _: !(builtins.hasAttr fileName reloadStagedEntries) && !(builtins.hasAttr fileName recreateStagedEntries))
      service.stagedEntries;
    recreateStagedEntries =
      lib.filterAttrs
      (fileName: _: builtins.elem fileName service.recreateTriggerFiles)
      service.stagedEntries;
    reloadDirRuntimePath = dirName:
      if builtins.hasAttr dirName service.dirRuntimePaths
      then service.dirRuntimePaths.${dirName}
      else if lib.hasPrefix "/" dirName
      then dirName
      else "${resolvedWorkingDir}/${dirName}";
    entryPermsJson = entry: {
      mode = entry.mode;
      user = ownerRefToString entry.user;
      group = ownerRefToString entry.group;
      scope = entry.scope;
    };
    dirHasStagedEntries = dirName:
      builtins.any
      (fileName: fileName == dirName || lib.hasPrefix "${dirName}/" fileName)
      (builtins.attrNames service.stagedEntries);
    dirOnce = dirName: entry:
      if entry.once != null
      then entry.once
      else entry.user == null && entry.group == null && !(dirHasStagedEntries dirName);
    dirPermsJson = dirName: entry:
      entryPermsJson entry
      // {
        once = dirOnce dirName entry;
      };
    sourceDirEntryPerms = entry:
      dirEntryDefaults
      // {
        mode =
          if entry.mode == null || entry.mode == "none"
          then dirEntryDefaults.mode
          else entry.mode;
        user = entry.user;
        group = entry.group;
        scope = entry.scope;
      };
    reloadDirEntry = dirName:
      if builtins.hasAttr dirName service.dirs
      then service.dirs.${dirName}
      else if builtins.hasAttr dirName service.files
      then sourceDirEntryPerms service.files.${dirName}
      else dirEntryDefaults;
    reloadDirMetadata = dirName:
      {
        name = dirName;
        dst = reloadDirRuntimePath dirName;
      }
      // dirPermsJson dirName (reloadDirEntry dirName);
    stagedFileActionInputs = entries: {
      sourcePaths = lib.mapAttrs (fileName: _: service.sourcePaths.${fileName}) entries;
      runtimePaths = lib.mapAttrs (fileName: _: service.runtimePaths.${fileName}) entries;
      stagedEntryPerms = lib.mapAttrs (_: entryPermsJson) entries;
    };
    sortJsonValues = values: lib.sort (a: b: builtins.toJSON a < builtins.toJSON b) values;
    secretSourceInput = file: let
      sourceHash = secretSourceHash file;
    in {
      inherit sourceHash;
      source =
        if sourceHash == null
        then file
        else null;
    };
    fileSecretSourceInput = entry: let
      sourceHash =
        if (entry.sourceHash or null) != null
        then entry.sourceHash
        else secretSourceHash entry.file;
    in {
      inherit sourceHash;
      source =
        if sourceHash == null
        then entry.file
        else null;
    };
    secretRestartInputs = {
      fileSecrets = sortJsonValues (
        map
        (entry:
          fileSecretSourceInput entry
          // entryPermsJson entry)
        (lib.attrValues service.fileSecrets)
      );
      envSecrets = sortJsonValues (
        map
        (entry:
          {
            sources = sortJsonValues (map secretSourceInput (lib.attrValues entry.entries));
          }
          // entryPermsJson entry)
        (lib.attrValues service.envSecrets)
      );
    };
    secretRecreateInputs = {
      fileSecrets =
        lib.mapAttrs (_: entry: {
          inherit
            (entry)
            mount
            mountPath
            readOnly
            services
            ;
        })
        service.fileSecrets;
      fileSecretRuntimePaths = service.fileSecretRuntimePaths;
      envSecrets =
        lib.mapAttrs (_: entry: {
          envVars = builtins.attrNames entry.entries;
        })
        service.envSecrets;
      envSecretRuntimePaths = service.envSecretRuntimePaths;
    };
    actionInputs = {
      reload = {
        reload = service.reload;
        reloadTag = service.reloadTag;
        dirs =
          map (dirName: {
            name = dirName;
            dst = reloadDirRuntimePath dirName;
            perms =
              if builtins.hasAttr dirName service.dirs
              then dirPermsJson dirName service.dirs.${dirName}
              else null;
          })
          service.reload.trigger.dirs;
        files = stagedFileActionInputs reloadStagedEntries;
      };
      restart =
        {
          unit = restartStampSystemdService;
          reload = service.reload;
          preStart = service.preStart;
          postStart = service.postStart;
          startStateStallSeconds = service.startStateStallSeconds;
          files = stagedFileActionInputs restartStagedEntries;
          dirs = lib.mapAttrs (dirName: entry: dirPermsJson dirName entry) restartDirs;
          dirRuntimePaths = restartDirRuntimePaths;
        }
        // secretRestartInputs;
      recreate =
        {
          composeArgs = service.composeArgs;
          composeFiles = resolvedComposeFiles;
          pullComposeFiles = resolvedPullComposeFiles;
          helperPath = podmanHelperPath;
          entryFile = service.entryFile;
          expectedComposeServices = service.knownSourceComposeServices;
          files = stagedFileActionInputs recreateStagedEntries;
          imageTag = service.imageTag;
        }
        // secretRecreateInputs;
      imagePull = {
        composeArgs = service.composeArgs;
        pullComposeFiles = resolvedPullComposeFiles;
        declaredImages = service.declaredImages;
        imageTag = service.imageTag;
      };
    };
    hashActionInput = value: builtins.hashString "sha256" (builtins.toJSON value);
    actionStamps = rec {
      reload =
        if nativeReloadEnabled
        then hashActionInput actionInputs.reload
        else "";
      restart = hashActionInput actionInputs.restart;
      recreate = hashActionInput actionInputs.recreate;
      imagePull = hashActionInput actionInputs.imagePull;
      restartPolicy = hashActionInput {
        policy = service.reconcilePolicy;
        reload = actionInputs.reload;
        restart = actionInputs.restart;
        recreate = actionInputs.recreate;
        reloadTag = service.reloadTag;
        bootTag = service.bootTag;
        recreateTag = service.recreateTag;
      };
      anyChange = hashActionInput {
        policy = service.reconcilePolicy;
        reload = actionInputs.reload;
        restart = actionInputs.restart;
        recreate = actionInputs.recreate;
        reloadTag = service.reloadTag;
        bootTag = service.bootTag;
        recreateTag = service.recreateTag;
      };
      policyNeutral = hashActionInput ({
          state = service.state;
          removalPolicy = service.removalPolicy;
          adopt = service.adopt;
          reload = actionInputs.reload;
          restart = actionInputs.restart;
          recreate = actionInputs.recreate;
          preStop = service.preStop;
          reloadTag = service.reloadTag;
          bootTag = service.bootTag;
          recreateTag = service.recreateTag;
        }
        // lib.optionalAttrs (resolvedUser != "root" && service.waitForNetwork) {
          rootlessNetworkReadiness = "network-online-before-rootless-netns-v1";
        });
      helperRecreate =
        if service.reconcilePolicy == "recreate"
        then anyChange
        else recreate;
    };
    lifecyclePolicy = let
      smart = service.reconcilePolicy == "auto";
      forcedRestart = service.reconcilePolicy == "restart";
      forcedRecreate = service.reconcilePolicy == "recreate";
      restartToRecreateCapableTransitionToken = "podman-compose/restart-to-recreate-capable-v1";
    in {
      helperRecreateStamp = actionStamps.helperRecreate;
      restartTriggers =
        lib.optionals smart [
          actionStamps.restart
          service.bootTag
          actionStamps.recreate
          service.recreateTag
        ]
        ++ lib.optionals forcedRestart [
          actionStamps.restartPolicy
        ]
        ++ lib.optionals forcedRecreate [
          actionStamps.anyChange
        ];
      reloadTriggers = lib.optionals (smart && actionStamps.reload != "") [
        actionStamps.reload
        service.reloadTag
      ];
      stampPayload =
        {
          kind = "podman-managed-unit";
          state = service.state;
          reconcilePolicy = service.reconcilePolicy;
          removalPolicy = service.removalPolicy;
          adopt = service.adopt;
        }
        // lib.optionalAttrs smart {
          restartStamp = actionStamps.restart;
          bootTag = service.bootTag;
          recreateStamp = actionStamps.recreate;
          recreateTag = service.recreateTag;
        }
        // lib.optionalAttrs forcedRestart {
          restartPolicyStamp = actionStamps.restartPolicy;
          recreateTag = service.recreateTag;
        }
        // lib.optionalAttrs forcedRecreate {
          anyChangeStamp = actionStamps.anyChange;
        };
      transitionNeutralStamp = actionStamps.policyNeutral;
      stopOnTransitionFrom =
        if forcedRestart
        then restartToRecreateCapableTransitionToken
        else null;
      stopOnTransitionTo =
        if smart || forcedRecreate
        then restartToRecreateCapableTransitionToken
        else null;
    };
    adoptionStamp = builtins.hashString "sha256" (builtins.toJSON {
      kind = "podman-compose-adoption";
      serviceName = resolvedSystemdServiceName;
      workingDir = resolvedWorkingDir;
    });
    helperMetadata = pkgs.writeText "podman-compose-${resolvedSystemdServiceName}.json" (
      builtins.toJSON {
        version = 10;
        serviceName = resolvedSystemdServiceName;
        workingDir = resolvedWorkingDir;
        adoptionStamp = adoptionStamp;
        state = service.state;
        reconcilePolicy = service.reconcilePolicy;
        removalPolicy = service.removalPolicy;
        adopt = service.adopt;
        preStart = service.preStart;
        postStart = service.postStart;
        preStop = service.preStop;
        composeArgs = service.composeArgs;
        composeFiles = resolvedComposeFiles;
        pullComposeFiles = resolvedPullComposeFiles;
        declaredImages = service.declaredImages;
        expectedComposeServices = service.knownSourceComposeServices;
        stagedDirs = map (dirName: let
          entry = service.dirs.${dirName};
        in
          {
            dst = service.dirRuntimePaths.${dirName};
          }
          // dirPermsJson dirName entry) (builtins.attrNames service.dirs);
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
        reload = {
          inherit (service.reload) method signal services;
          dirs = map reloadDirMetadata service.reload.trigger.dirs;
          stagedFiles = map (fileName: let
            entry = reloadStagedEntries.${fileName};
          in
            {
              src = service.sourcePaths.${fileName};
              dst = service.runtimePaths.${fileName};
              dstDir = builtins.dirOf service.runtimePaths.${fileName};
              dstDirMode = "0750";
            }
            // entryPermsJson entry) (builtins.attrNames reloadStagedEntries);
        };
        recreateTag = service.recreateTag;
        restartStamp = actionStamps.restart;
        recreateStamp = lifecyclePolicy.helperRecreateStamp;
        recreateClassStamp = actionStamps.recreate;
        imagePullStamp = actionStamps.imagePull;
        startWorkerUnit = "";
        longRunning = service.longRunning;
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
    helperEnvironment =
      [
        "PATH=${podmanHelperPath}"
        "NIX_PODMAN_COMPOSE_METADATA=${helperMetadata}"
        "NIX_PODMAN_COMPOSE_SERVICE_NAME=${resolvedSystemdServiceName}"
      ]
      ++ lib.optional (service.startStateStallSeconds != null) "NIX_PODMAN_COMPOSE_START_STATE_STALL_SECONDS=${toString service.startStateStallSeconds}";
    stampHelperEnvironment = [
      "PATH=${podmanHelperPath}"
      "NIX_PODMAN_COMPOSE_METADATA=<generation-local-metadata>"
      "NIX_PODMAN_COMPOSE_SERVICE_NAME=${resolvedSystemdServiceName}"
    ];
    baseSystemdService = {
      description = "podman: ${resolvedUser}: ${serviceName}";
      after = lib.unique (
        networkOnlineUnits
        ++ rootlessIdmapMigrateUnit
        ++ [stageUnit]
        ++ lib.optional hasBootstrapUnit bootstrapUnit
        ++ dependsOnUnits
        ++ wantsUnits
        ++ lib.optional hasImagePullUnit imagePullUnit
      );
      wants = lib.unique (networkOnlineUnits ++ wantsUnits ++ lib.optional hasImagePullUnit imagePullUnit);
      wantedBy = lib.optional serviceAutoStarts "${userManagedTargetName}.target";
      restartIfChanged = service.state == "running";
      stopIfChanged = service.state == "running";
      unitConfig =
        conditionUserConfig
        // {
          Requires = lib.unique (
            rootlessIdmapMigrateUnit
            ++ [stageUnit]
            ++ lib.optional hasBootstrapUnit bootstrapUnit
            ++ dependsOnUnits
            ++ lib.optional hasImagePullUnit imagePullUnit
          );
        };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        Environment = helperEnvironment;
        # Allow first start when the compose working directory doesn't exist yet.
        # ExecStart creates it before invoking podman compose.
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} start-staged";
        ExecStop = "${helperScript} stop";
        ExecReload = "${helperScript} reload";
        ExecStopPost = "${helperScript} post-stop";
        # Keep helper subprocesses in the service kill boundary. If a start
        # path times out while podman-compose or flock is blocked, leaving
        # those children alive can wedge the lifecycle lock for the next
        # activation.
        KillMode = "control-group";
        Delegate = true;
        Restart = "on-failure";
        TimeoutStartSec = lib.mkDefault 120;
        RestartPreventExitStatus = "75";
        TimeoutStopSec = lib.mkDefault 180;
      };
    };
    imagePullSystemdService = lib.optionalAttrs hasImagePullUnit {
      description = "podman: ${resolvedUser}: ${serviceName} image pull";
      after = lib.unique networkOnlineUnits;
      wants = lib.unique networkOnlineUnits;
      unitConfig = conditionUserConfig;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment =
          helperEnvironment
          ++ [
            "NIX_PODMAN_COMPOSE_IMAGE_TAG=${service.imageTag}"
          ];
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} image-pull";
        TimeoutStartSec = 120;
      };
    };
    stageSystemdService = {
      description = "podman: ${resolvedUser}: ${serviceName} stage";
      after = lib.unique (networkOnlineUnits ++ rootlessIdmapMigrateUnit);
      wants = lib.unique networkOnlineUnits;
      unitConfig =
        conditionUserConfig
        // lib.optionalAttrs (rootlessIdmapMigrateUnit != []) {
          Requires = rootlessIdmapMigrateUnit;
        };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment = helperEnvironment;
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} stage";
        TimeoutStartSec = lib.mkDefault 120;
      };
    };
    bootstrapSystemdService = lib.optionalAttrs hasBootstrapUnit {
      description = "podman: ${resolvedUser}: ${serviceName} bootstrap";
      after = [stageUnit];
      unitConfig =
        conditionUserConfig
        // {
          Requires = [stageUnit];
        };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment = helperEnvironment;
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} bootstrap";
        TimeoutStartSec = lib.mkDefault 120;
      };
    };
    reconcileSystemdService = lib.optionalAttrs hasReconcileUnit {
      description = "podman: ${resolvedUser}: ${serviceName} reconcile";
      after = ["${resolvedSystemdServiceName}.service"];
      unitConfig =
        conditionUserConfig
        // {
          Requires = ["${resolvedSystemdServiceName}.service"];
        };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment = helperEnvironment;
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} reconcile";
        TimeoutStartSec = lib.mkDefault 120;
      };
    };
    verifySystemdService = {
      description = "podman: ${resolvedUser}: ${serviceName} verify";
      after = ["${resolvedSystemdServiceName}.service"] ++ lib.optional hasReconcileUnit reconcileUnit;
      unitConfig =
        conditionUserConfig
        // {
          Requires = ["${resolvedSystemdServiceName}.service"] ++ lib.optional hasReconcileUnit reconcileUnit;
        };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Environment = helperEnvironment;
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} verify";
        TimeoutStartSec = lib.mkDefault 120;
      };
    };
    readySystemdTarget = {
      description = "podman: ${resolvedUser}: ${serviceName} ready";
      unitConfig =
        conditionUserConfig
        // {
          X-StopOnReconfiguration = true;
          Requires = [verifyUnit];
          After = [verifyUnit];
        };
    };
    mergedSystemdServiceWithoutLifecycleTriggers = lib.recursiveUpdate baseSystemdService service.serviceOverrides;
    mergedSystemdService =
      mergedSystemdServiceWithoutLifecycleTriggers
      // {
        restartTriggers = lib.unique ((mergedSystemdServiceWithoutLifecycleTriggers.restartTriggers or []) ++ lifecyclePolicy.restartTriggers);
        reloadTriggers = lib.unique ((mergedSystemdServiceWithoutLifecycleTriggers.reloadTriggers or []) ++ lifecyclePolicy.reloadTriggers);
      };
    stampBaseSystemdService =
      baseSystemdService
      // {
        serviceConfig =
          baseSystemdService.serviceConfig
          // {
            Environment = stampHelperEnvironment;
          };
      };
    restartSystemdService = lib.recursiveUpdate stampBaseSystemdService service.serviceOverrides;
    normalizeGeneratedHelperCommand = action: value:
      if value == "${helperScript} ${action}"
      then "<podman-compose-helper> ${action}"
      else value;
    normalizeGeneratedHelperServiceConfig = serviceConfig:
      serviceConfig
      // lib.optionalAttrs (serviceConfig ? ExecStart) {
        ExecStart = normalizeGeneratedHelperCommand "start" serviceConfig.ExecStart;
      }
      // lib.optionalAttrs (serviceConfig ? ExecStop) {
        ExecStop = normalizeGeneratedHelperCommand "stop" serviceConfig.ExecStop;
      }
      // lib.optionalAttrs (serviceConfig ? ExecReload) {
        ExecReload = normalizeGeneratedHelperCommand "reload" serviceConfig.ExecReload;
      }
      // lib.optionalAttrs (serviceConfig ? ExecStopPost) {
        ExecStopPost = normalizeGeneratedHelperCommand "post-stop" serviceConfig.ExecStopPost;
      };
    restartStampServiceConfig = normalizeGeneratedHelperServiceConfig (restartSystemdService.serviceConfig or {});
    restartStampSystemdService =
      restartSystemdService
      // {
        serviceConfig = builtins.removeAttrs restartStampServiceConfig [
          "TimeoutStartSec"
          "TimeoutStopSec"
        ];
      };
  in {
    systemdServiceName = resolvedSystemdServiceName;
    systemdUser = resolvedUser;
    helperMetadata = helperMetadata;
    systemdService = mergedSystemdService;
    systemdReadyTargetName = readyTargetName;
    systemdUserManagedTargetName = userManagedTargetName;
    systemdUserManagedReadyTargetName = userManagedReadyTargetName;
    autoStartEnabled = serviceAutoStarts;
    auxiliarySystemdUserServices =
      [
        {
          name = stageServiceName;
          value = stageSystemdService;
        }
        {
          name = verifyServiceName;
          value = verifySystemdService;
        }
      ]
      ++ lib.optional hasBootstrapUnit {
        name = bootstrapServiceName;
        value = bootstrapSystemdService;
      }
      ++ lib.optional hasReconcileUnit {
        name = reconcileServiceName;
        value = reconcileSystemdService;
      }
      ++ lib.optional hasImagePullUnit {
        name = imagePullServiceName;
        value = imagePullSystemdService;
      };
    auxiliarySystemdUserTargets = [
      {
        name = readyTargetName;
        value = readySystemdTarget;
      }
    ];
    lifecyclePolicy = lifecyclePolicy;
    inherit (service) state reconcilePolicy removalPolicy adopt autoStart longRunning timeoutReadySeconds imageTag recreateTag bootTag reloadTag waitForNetwork hasComposeEntry;
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
  userUidString = user:
    if user == "root"
    then "0"
    else if builtins.hasAttr user config.users.users && config.users.users.${user}.uid != null
    then toString config.users.users.${user}.uid
    else throw "services.podman-compose: rootless stack user '${user}' must exist in users.users with a non-null uid.";
  controlRegistryFile = pkgs.writeText "podman-compose-control-registry.json" (builtins.toJSON (
    lib.listToAttrs (
      map
      (service:
        lib.nameValuePair service.systemdServiceName {
          user = service.systemdUser;
          uid = userUidString service.systemdUser;
          unit = "${service.systemdServiceName}.service";
          serviceName = service.systemdServiceName;
          metadataFile = service.helperMetadata;
          timeoutReadySeconds = service.timeoutReadySeconds;
        })
      resolvedServices
    )
  ));
  imagePullPlanFile = pkgs.writeText "podman-compose-image-pulls.json" (builtins.toJSON (
    map
    (service: {
      user = service.systemdUser;
      uid = userUidString service.systemdUser;
      serviceName = service.systemdServiceName;
      metadataFile = service.helperMetadata;
      helper = helperScript;
      imageTag = service.imageTag;
    })
    (builtins.filter (service: service.hasComposeEntry) resolvedServices)
  ));
  controlPackage = pkgs.writeShellApplication {
    name = "podman-composectl";
    excludeShellChecks = [
      "SC1091"
      "SC2034"
    ];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      registry="''${NIX_PODMAN_COMPOSE_CONTROL_REGISTRY:-/run/current-system/share/podman-compose/control-registry.json}"
      helper=${lib.escapeShellArg helperScript}
      source ${./composectl.sh}
      main "$@"
    '';
  };
  imagePullAllPackage = pkgs.writeShellApplication {
    name = "podman-compose-image-pull-all";
    excludeShellChecks = [
      "SC1091"
      "SC2034"
    ];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.getent
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      plan="''${NIX_PODMAN_COMPOSE_IMAGE_PULL_PLAN:-/run/current-system/share/podman-compose/image-pulls.json}"
      source ${./image-pull-all.sh}
      main "$@"
    '';
  };
  rootlessIdmapMigratePackage = pkgs.writeShellApplication {
    name = "podman-rootless-idmap-migrate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnused
      pkgs.jq
      pkgs.podman
    ];
    text = builtins.readFile ./rootless-idmap-migrate.sh;
  };

  allExposedPortEntries = lib.concatLists (
    lib.mapAttrsToList (
      stackName: stack:
        lib.concatLists (
          lib.mapAttrsToList (
            serviceName: service:
              lib.concatLists (
                lib.mapAttrsToList (
                  portName: portCfg:
                    map (protocol: {
                      key = "${protocol}:${toString portCfg.port}";
                      inherit stackName serviceName portName protocol portCfg;
                      port = portCfg.port;
                    })
                    (portCfg.protocols or ["tcp"])
                )
                service.exposedPorts
              )
          )
          stack.instances
        )
    )
    cfg
  );
  allExposedPorts = map (entry: entry.portCfg) allExposedPortEntries;
  duplicatedExposedPortKeys = flakeUtils.duplicateValues (map (entry: entry.key) allExposedPortEntries);
  duplicatedExposedPortEntries =
    lib.filter (entry: builtins.elem entry.key duplicatedExposedPortKeys) allExposedPortEntries;
  describeExposedPortEntry = entry: "${entry.stackName}.${entry.serviceName}.${entry.portName}=${entry.protocol}/${toString entry.port}";
  reservedGeneratedPathViolations = lib.concatLists (
    lib.mapAttrsToList (
      stackName: stack:
        lib.concatLists (
          lib.mapAttrsToList (
            serviceName: service:
              map
              (path: "${stackName}.${serviceName}.${path}")
              (lib.filter isReservedGeneratedPath service.userDeclaredRuntimePaths)
          )
          stack.instances
        )
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
    resolvedServices
    ++ (map rootlessIdmapMigrateUserServiceNameForUser rootlessStackUsersWithConfig);
  duplicateSystemdUserServiceNames = flakeUtils.duplicateValues generatedSystemdUserServiceNames;
  generatedSystemdUserTargetNames =
    lib.concatMap
    (service: map (target: target.name) service.auxiliarySystemdUserTargets)
    resolvedServices
    ++ map managedTargetNameForUser stackUsers
    ++ map managedReadyTargetNameForUser stackUsers;
  duplicateSystemdUserTargetNames = flakeUtils.duplicateValues generatedSystemdUserTargetNames;
  autoStartServicesForUser = user:
    builtins.filter (
      service:
        service.systemdUser
        == user
        && service.autoStartEnabled
    )
    resolvedServices;
  mkManagedUserTarget = user: let
    services = autoStartServicesForUser user;
  in {
    name = managedTargetNameForUser user;
    value = {
      description = "Managed ${user} user services";
      wantedBy = lib.optional (services != []) "default.target";
      wants = map (service: "${service.systemdServiceName}.service") services;
      unitConfig.ConditionUser = user;
    };
  };
  mkManagedReadyUserTarget = user: let
    services = autoStartServicesForUser user;
  in {
    name = managedReadyTargetNameForUser user;
    value = {
      description = "Managed ${user} user services ready";
      wantedBy = lib.optional (services != []) "default.target";
      unitConfig = {
        ConditionUser = user;
        X-StopOnReconfiguration = true;
        Requires = map (service: "${service.systemdReadyTargetName}.target") services;
        After = map (service: "${service.systemdReadyTargetName}.target") services;
      };
    };
  };
  mkMigrationManagedUser = user: let
    services = builtins.filter (service: service.systemdUser == user) resolvedServices;
    autoStartServices = autoStartServicesForUser user;
    targetIsActive = autoStartServices != [];
  in {
    ${user} = {
      services = lib.listToAttrs (
        map
        (service: {
          name = "${service.systemdServiceName}.service";
          value = {
            stopOnDrain = service.state == "running";
            startOnResume = false;
          };
        })
        services
      );
      targets = {
        "${managedTargetNameForUser user}.target" = {
          stopOnDrain = targetIsActive;
          startOnResume = targetIsActive;
        };
        "${managedReadyTargetNameForUser user}.target" = {
          stopOnDrain = targetIsActive;
          startOnResume = targetIsActive;
        };
      };
    };
  };
  stackUsers = lib.unique (map (service: service.systemdUser) resolvedServices);
  rootlessStackUsers = builtins.filter (user: user != "root") stackUsers;
  rootlessStackUserHasConfig = user:
    builtins.hasAttr user config.users.users
    && config.users.users.${user}.uid != null
    && config.users.users.${user}.home != null;
  rootlessStackUsersWithConfig = builtins.filter rootlessStackUserHasConfig rootlessStackUsers;
  rootlessStackUserNeedsNetworkOnline = user:
    builtins.any (
      service:
        service.systemdUser
        == user
        && service.waitForNetwork
    )
    resolvedServices;
  rootlessStackUserNetworkOnlineUnits = user:
    lib.optional (rootlessStackUserNeedsNetworkOnline user) "network-online.target";
  serviceNameUserKey = user: lib.strings.sanitizeDerivationName user;
  managedTargetNameForUser = user: "${serviceNameUserKey user}-managed";
  managedReadyTargetNameForUser = user: "${serviceNameUserKey user}-managed-ready";
  rootlessIdmapMigrateUserServiceNameForUser = user: "podman-rootless-idmap-migrate-${serviceNameUserKey user}";
  # Rootless Podman can keep a stale single-id namespace after subuid/subgid
  # ranges appear; migrate before compose starts so container ids can map.
  mkRootlessIdmapMigrateUserService = user: let
    userCfg = config.users.users.${user};
    home = userCfg.home;
    serviceName = rootlessIdmapMigrateUserServiceNameForUser user;
    networkOnlineUnits = rootlessStackUserNetworkOnlineUnits user;
  in {
    name = serviceName;
    value = {
      description = "Reconcile rootless Podman uid/gid map for ${user}";
      after = networkOnlineUnits;
      wants = networkOnlineUnits;
      restartTriggers = [rootlessIdmapMigratePackage];
      restartIfChanged = true;
      stopIfChanged = true;
      unitConfig.ConditionUser = user;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "HOME=${home}"
          "PATH=${podmanHelperPath}"
        ];
        ExecStart = "${rootlessIdmapMigratePackage}/bin/podman-rootless-idmap-migrate ${lib.escapeShellArgs [user home]}";
      };
    };
  };
  declaredSubnets = lib.concatLists (
    lib.mapAttrsToList
    (stackName: stack:
      lib.mapAttrsToList
      (serviceName: service: {
        inherit stackName serviceName;
        subnet = service.subnet;
      })
      (lib.filterAttrs (_: service: service.subnet != null) stack.instances))
    cfg
  );
  duplicatedSubnets = flakeUtils.duplicateValues (map (entry: entry.subnet) declaredSubnets);
  describeSubnetEntry = entry: "${entry.stackName}.${entry.serviceName}=${entry.subnet}";
  duplicatedSubnetEntries =
    lib.filter (entry: builtins.elem entry.subnet duplicatedSubnets) declaredSubnets;
  describeEntryFile = entryFile:
    if entryFile == null
    then "<null>"
    else if builtins.isList entryFile
    then lib.concatStringsSep ", " entryFile
    else toString entryFile;
in {
  imports = [
    ../services/migration-manager/options.nix
  ];

  options.services.podman-compose = lib.mkOption {
    type = lib.types.attrsOf stackType;
    default = {};
    description = "Podman compose stacks. Example: services.podman-compose.stack1.instances.web = { ... };";
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
        normalizeTrustedCaCertificateEntry = entry:
          applyEntryDefaults trustedCaCertificateEntryDefaults (
            if builtins.isPath entry || builtins.isString entry
            then {file = entry;}
            else entry
          );
        normalizeTrustedCaDefaultEntry = defaultName: entry: let
          normalized = applyEntryDefaults trustedCaDefaultEntryDefaults (
            if builtins.isPath entry || builtins.isString entry
            then {file = entry;}
            else entry
          );
        in
          normalized
          // {
            name =
              if normalized.name == null
              then defaultName
              else normalized.name;
          };
        trustedCaInjections = trustedCa:
          if builtins.isBool trustedCa
          then lib.optional trustedCa {}
          else if builtins.isList trustedCa
          then
            if lib.all builtins.isString trustedCa
            then [{services = trustedCa;}]
            else if lib.all builtins.isAttrs trustedCa
            then trustedCa
            else throw "services.podman-compose.${stackName}: trustedCa lists must contain either service-name strings or CA attrsets, not a mix."
          else [trustedCa];
        trustedCaDefaultCertificates = defaultEntries: trustedCa:
          lib.listToAttrs (
            map (injection: let
              publicRoots = injection.publicRoots or true;
              defaultName =
                if publicRoots
                then "caBundle"
                else "ca";
              defaultEntryOrNull = defaultEntries.${defaultName} or null;
              defaultEntry =
                if defaultEntryOrNull == null
                then throw "services.podman-compose.${stackName}: trustedCa default '${defaultName}' is not defined."
                else defaultEntryOrNull;
              certName =
                if (injection.name or null) == null
                then defaultEntry.name
                else injection.name;
              entry =
                builtins.removeAttrs defaultEntry ["name"]
                // builtins.removeAttrs injection ["publicRoots" "name"];
            in {
              name = certName;
              value = entry;
            })
            (trustedCaInjections trustedCa)
          );
        trustedCaCertificateFileSecretEntry = entry: {
          file = toString entry.file;
          mode = entry.mode;
          user = entry.user;
          group = entry.group;
          scope = entry.scope;
          mount = true;
          mountPath = entry.mountPath;
          readOnly = entry.readOnly;
          services = entry.services;
          sourceHash =
            if entry.sourceHash != null
            then entry.sourceHash
            else if entry.sourceHashInputs != []
            then sourceHashFromInputs entry.sourceHashInputs
            else if entry.sourceHashFile == null
            then null
            else builtins.hashFile "sha256" entry.sourceHashFile;
        };
        normalizeEnvSecretEntry = entry:
          envSecretEntryDefaults // {entries = entry;};
        renderEntry = serviceName: fileName: entry:
          if entry.source != null
          then entry.source
          else let
            safeName = builtins.replaceStrings ["/" "."] ["__" "_"] fileName;
            outName = "podman-compose-${stackName}-${serviceName}-${safeName}";
          in
            pkgs.writeText outName entry.text;
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
        mkPullSourceDir = serviceName: sourcePaths: let
          installEntries =
            lib.mapAttrsToList (
              fileName: sourcePath: ''
                install -Dm0444 ${sourcePath} "$out"/${lib.escapeShellArg fileName}
              ''
            )
            sourcePaths;
        in
          pkgs.runCommand "podman-compose-${stackName}-${serviceName}-pull-sources" {} ''
            ${lib.concatStringsSep "\n" installEntries}
          '';
        stripVolumeSourceQuotes = source:
          builtins.replaceStrings ["\"" "'"] ["" ""] (toString source);
        volumeSourceFromShortSyntax = volume: let
          parts = lib.splitString ":" (stripVolumeSourceQuotes volume);
        in
          if parts == []
          then null
          else builtins.head parts;
        isLikelyHostBindSource = source:
          source
          != null
          && (
            lib.hasPrefix "." source
            || lib.hasPrefix "/" source
          );
        volumeSourceFromEntry = volume:
          if builtins.isString volume
          then volumeSourceFromShortSyntax volume
          else if
            builtins.isAttrs volume
            && builtins.hasAttr "source" volume
            && ((volume.type or "bind") == "bind")
          then stripVolumeSourceQuotes volume.source
          else null;
        volumeSourcesFromComposeAttrs = compose:
          if
            builtins.isAttrs compose
            && builtins.hasAttr "services" compose
            && builtins.isAttrs compose.services
          then
            lib.concatLists (
              lib.mapAttrsToList (
                _: composeService:
                  map volumeSourceFromEntry (composeService.volumes or [])
              )
              compose.services
            )
          else [];
        volumeSourcesFromComposeText = text:
          lib.concatMap
          (line: let
            shortSyntaxMatch = builtins.match "[[:space:]]*-[[:space:]]*['\"]?((\\./|/)[^:'\"[:space:]]+)['\"]?:.*" line;
            longSyntaxMatch = builtins.match "[[:space:]]*(source|src):[[:space:]]*['\"]?((\\./|/)[^'\"[:space:]]+)['\"]?[[:space:]]*" line;
          in
            if shortSyntaxMatch != null
            then [(stripVolumeSourceQuotes (builtins.head shortSyntaxMatch))]
            else if longSyntaxMatch != null
            then [(stripVolumeSourceQuotes (builtins.elemAt longSyntaxMatch 1))]
            else [])
          (lib.splitString "\n" text);
      in
        stack
        // (let
          normalizedTrustedCaDefaults = lib.mapAttrs (name: entry:
            if entry == null
            then null
            else normalizeTrustedCaDefaultEntry name entry)
          stack.trustedCaDefaults;
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
                  else throw "services.podman-compose.${stackName}: stack user '${resolvedUser}' must exist in config.users.users with a non-null uid when using function-valued instances.";
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
              baseService =
                serviceDefaults
                // {
                  timeoutReadySeconds = stack.timeoutReadySeconds;
                }
                // service;
              effectiveReconcilePolicy =
                if baseService.reconcilePolicy == "inherit"
                then stack.reconcilePolicy
                else baseService.reconcilePolicy;
              effectiveRemovalPolicy =
                if baseService.removalPolicy == "inherit"
                then stack.removalPolicy
                else baseService.removalPolicy;
              defaultTrustedCaCertificates =
                trustedCaDefaultCertificates normalizedTrustedCaDefaults baseService.trustedCa;
              normalizedTrustedCaCertificates =
                lib.mapAttrs (_: normalizeTrustedCaCertificateEntry) (defaultTrustedCaCertificates // baseService.trustedCaCertificates);
              trustedCaFileSecrets =
                lib.mapAttrs (_: trustedCaCertificateFileSecretEntry) normalizedTrustedCaCertificates;
              normalizedService =
                baseService
                // {
                  reconcilePolicy = effectiveReconcilePolicy;
                  removalPolicy = effectiveRemovalPolicy;
                  autoStart =
                    if baseService.state == "stopped"
                    then false
                    else if baseService.autoStart == null
                    then stack.autoStart
                    else baseService.autoStart;
                  timeoutReadySeconds =
                    if baseService.timeoutReadySeconds == null
                    then stack.timeoutReadySeconds
                    else baseService.timeoutReadySeconds;
                  dirs = lib.mapAttrs (_: applyEntryDefaults dirEntryDefaults) baseService.dirs;
                  envSecrets = lib.mapAttrs (_: normalizeEnvSecretEntry) baseService.envSecrets;
                  files = lib.mapAttrs (_: normalizeFileEntry) baseService.files;
                  fileSecrets = lib.mapAttrs (_: normalizeFileSecretEntry) (baseService.fileSecrets // trustedCaFileSecrets);
                  trustedCaCertificates = normalizedTrustedCaCertificates;
                };
              useSource = normalizedService.source != null;
              sourceCompose =
                if builtins.isPath normalizedService.source
                then builtins.readFile normalizedService.source
                else normalizedService.source;
              sourceTextComposeServices =
                if builtins.isString sourceCompose
                then composeServicesFromText sourceCompose
                else [];
              sourceDeclaredImages =
                if
                  builtins.isAttrs sourceCompose
                  && builtins.hasAttr "services" sourceCompose
                  && builtins.isAttrs sourceCompose.services
                then
                  lib.unique (
                    lib.filter (image: image != null) (
                      lib.mapAttrsToList (_: composeService: composeService.image or null) sourceCompose.services
                    )
                  )
                else if builtins.isString sourceCompose
                then composeImagesFromText sourceCompose
                else [];
              sourceDeclaredComposeServices =
                if
                  builtins.isAttrs sourceCompose
                  && builtins.hasAttr "services" sourceCompose
                  && builtins.isAttrs sourceCompose.services
                then builtins.attrNames sourceCompose.services
                else if sourceTextComposeServices != []
                then sourceTextComposeServices
                else [serviceName];
              knownSourceComposeServices =
                if
                  builtins.isAttrs sourceCompose
                  && builtins.hasAttr "services" sourceCompose
                  && builtins.isAttrs sourceCompose.services
                then builtins.attrNames sourceCompose.services
                else if sourceTextComposeServices != []
                then sourceTextComposeServices
                else [];
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
              trustedCaEnvironmentForService = composeServiceName:
                lib.listToAttrs (
                  lib.concatMap (
                    certName: let
                      entry = normalizedService.trustedCaCertificates.${certName};
                      mountPath = fileSecretMountPath certName normalizedService.fileSecrets.${certName};
                    in
                      lib.optionals (builtins.elem composeServiceName (fileSecretMountServices entry)) (
                        map (envVar: {
                          name = envVar;
                          value = mountPath;
                        })
                        entry.envVars
                      )
                  ) (builtins.attrNames normalizedService.trustedCaCertificates)
                );
              fileSecretsOverride =
                if fileSecretTargetServices == []
                then {}
                else {
                  services = lib.listToAttrs (
                    map (
                      composeServiceName: let
                        trustedCaEnvironment = trustedCaEnvironmentForService composeServiceName;
                      in {
                        name = composeServiceName;
                        value =
                          {
                            volumes = fileSecretMountsForService composeServiceName;
                          }
                          // lib.optionalAttrs (trustedCaEnvironment != {}) {
                            environment = trustedCaEnvironment;
                          };
                      }
                    )
                    fileSecretTargetServices
                  );
                };
              filesExpanded =
                lib.concatMapAttrs (dstPath: entry: expandFileEntry dstPath entry) normalizedService.files;
              effectiveEntries =
                (lib.optionalAttrs useSource {"compose.yml" = mkGeneratedEntry sourceCompose;})
                // filesExpanded
                // (lib.optionalAttrs (envSecretsOverride != {}) {"${envSecretsOverrideFileName}" = mkGeneratedEntry envSecretsOverride;})
                // (lib.optionalAttrs (fileSecretsOverride != {}) {"${fileSecretsOverrideFileName}" = mkGeneratedEntry fileSecretsOverride;});
              implicitEntryFileCandidates =
                lib.filter
                (fileName: builtins.hasAttr fileName effectiveEntries)
                defaultComposeEntryFiles;
              implicitEntryFiles =
                if builtins.length implicitEntryFileCandidates == 1
                then implicitEntryFileCandidates
                else [];
              baseEntryFiles =
                if normalizedService.entryFile != null
                then
                  if builtins.isList normalizedService.entryFile
                  then normalizedService.entryFile
                  else [normalizedService.entryFile]
                else if useSource
                then ["compose.yml"]
                else implicitEntryFiles;
              hasComposeEntry = baseEntryFiles != [];
              generatedOverrideFiles =
                lib.optionals (envSecretsOverride != {}) [envSecretsOverrideFileName]
                ++ lib.optionals (fileSecretsOverride != {}) [fileSecretsOverrideFileName];
              normalizedEntryFile =
                if baseEntryFiles == []
                then null
                else if generatedOverrideFiles == [] && normalizedService.entryFile != null
                then normalizedService.entryFile
                else baseEntryFiles ++ generatedOverrideFiles;
              declaredSourceDirNames = builtins.attrNames (
                lib.filterAttrs (
                  _: entry:
                    entry.source
                    != null
                    && builtins.isPath entry.source
                    && (let
                      pathString = toString entry.source;
                      pathName = builtins.baseNameOf pathString;
                      pathParent = builtins.dirOf pathString;
                      pathKind = (builtins.readDir pathParent).${pathName} or null;
                    in
                      pathKind == "directory")
                )
                normalizedService.files
              );
              validReloadOnChangeDirs = lib.unique (
                (builtins.attrNames normalizedService.dirs) ++ declaredSourceDirNames
              );
              invalidReloadOnChangeDirs =
                lib.filter
                (dirName: !(builtins.elem dirName validReloadOnChangeDirs))
                normalizedService.reload.trigger.dirs;
              resolvedWorkingDir =
                if normalizedService.workingDir != null
                then normalizedService.workingDir
                else "${stack.stackDir}/${serviceName}";
              normalizeComposeBindSource = source: let
                strippedSource = stripVolumeSourceQuotes source;
                withoutDotSlash =
                  if lib.hasPrefix "./" strippedSource
                  then lib.removePrefix "./" strippedSource
                  else strippedSource;
              in
                if lib.hasPrefix "${resolvedWorkingDir}/" withoutDotSlash
                then lib.removePrefix "${resolvedWorkingDir}/" withoutDotSlash
                else withoutDotSlash;
              composeBindSources = lib.unique (
                map normalizeComposeBindSource (
                  builtins.filter isLikelyHostBindSource (
                    volumeSourcesFromComposeAttrs sourceCompose
                    ++ lib.optionals (builtins.isString sourceCompose) (volumeSourcesFromComposeText sourceCompose)
                  )
                )
              );
              invalidReloadExternalFiles =
                lib.filter
                (fileName: !(builtins.hasAttr fileName filesExpanded))
                normalizedService.reload.trigger.externalFiles;
              bindMountedStagedEntries =
                lib.filter
                (fileName: builtins.elem fileName composeBindSources)
                (builtins.attrNames effectiveEntries);
              invalidRecreateTriggerFiles =
                lib.filter
                (fileName: !(builtins.hasAttr fileName filesExpanded))
                normalizedService.recreate.trigger.files;
              recreateTriggerFiles =
                lib.unique (normalizedService.recreate.trigger.files ++ bindMountedStagedEntries ++ generatedOverrideFiles);
              reloadTriggerFiles = lib.unique (
                normalizedService.reload.trigger.externalFiles
                ++ lib.filter
                (fileName:
                  builtins.any
                  (dirName: pathMatchesDir dirName fileName)
                  normalizedService.reload.trigger.dirs)
                (builtins.attrNames effectiveEntries)
              );
              conflictingReloadRecreateFiles =
                lib.filter
                (fileName: builtins.elem fileName recreateTriggerFiles)
                reloadTriggerFiles;
              fileSecretRuntimePaths =
                lib.mapAttrs
                (secretName: _: "${resolvedWorkingDir}/${fileSecretsRuntimeDirName}/${secretName}")
                normalizedService.fileSecrets;
              dirRuntimePaths =
                lib.mapAttrs
                (
                  dirName: _:
                    if dirName == ""
                    then resolvedWorkingDir
                    else if lib.hasPrefix "/" dirName
                    then dirName
                    else "${resolvedWorkingDir}/${dirName}"
                )
                normalizedService.dirs;
              envSecretRuntimePaths =
                lib.mapAttrs
                (composeServiceName: _: "${resolvedWorkingDir}/${envSecretsRuntimeDirName}/${composeServiceName}.env")
                normalizedService.envSecrets;
              sourcePaths = lib.mapAttrs (fileName: entry: renderEntry serviceName fileName entry) effectiveEntries;
              pullSourceDir = mkPullSourceDir serviceName sourcePaths;
            in
              normalizedService
              // {
                resolvedWorkingDir = resolvedWorkingDir;
                hasComposeEntry = hasComposeEntry;
                fileSecretRuntimePaths = fileSecretRuntimePaths;
                dirRuntimePaths = dirRuntimePaths;
                envSecretRuntimePaths = envSecretRuntimePaths;
                knownSourceComposeServices = knownSourceComposeServices;
                declaredImages = sourceDeclaredImages;
                stagedEntries = effectiveEntries;
                sourcePaths = sourcePaths;
                pullSourcePaths = lib.mapAttrs (fileName: _: "${pullSourceDir}/${fileName}") effectiveEntries;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveEntries;
                entryFile = normalizedEntryFile;
                pullEntryFiles = baseEntryFiles;
                userDeclaredRuntimePaths = (builtins.attrNames filesExpanded) ++ (builtins.attrNames normalizedService.dirs);
                validReloadOnChangeDirs = validReloadOnChangeDirs;
                invalidReloadOnChangeDirs = invalidReloadOnChangeDirs;
                invalidReloadExternalFiles = invalidReloadExternalFiles;
                bindMountedStagedEntries = bindMountedStagedEntries;
                invalidRecreateTriggerFiles = invalidRecreateTriggerFiles;
                recreateTriggerFiles = recreateTriggerFiles;
                conflictingReloadRecreateFiles = conflictingReloadRecreateFiles;
                implicitEntryFileCandidates = implicitEntryFileCandidates;
              })
            instancesWithContext;
        in {
          instances = resolvedInstances;
          nginx-proxy-vhosts =
            nginxLib.proxyVhostsFromInstances {
              defaultHost = stack.nginxDefaultHost;
            }
            resolvedInstances;
          nginxRoutes =
            nginxLib.routesFromInstances {
              defaultHost = stack.nginxDefaultHost;
            }
            resolvedInstances;
          tunnelEndpoints = tunnelsLib.endpointsFromInstances stackName resolvedInstances;
          tunnelIngress = tunnelsLib.ingressByKindFromInstances stackName resolvedInstances;
        }))
      stacks;
  };

  config = lib.mkIf hasStacks {
    system = {
      systemBuilderCommands = ''
        install -Dm0444 ${lib.escapeShellArg controlRegistryFile} "$out/share/podman-compose/control-registry.json"
        install -Dm0444 ${lib.escapeShellArg imagePullPlanFile} "$out/share/podman-compose/image-pulls.json"
      '';
      build = {
        podmanComposeControlRegistry = controlRegistryFile;
        podmanComposeImagePullPlan = imagePullPlanFile;
      };
    };

    environment.systemPackages = with pkgs;
      [
        podman
        podman-compose
      ]
      ++ [
        controlPackage
        imagePullAllPackage
      ];

    services.migration-manager.managedUnits.users = lib.mkMerge (
      map mkMigrationManagedUser stackUsers
    );

    networking.firewall.allowedTCPPorts = firewallPortsForProtocol "tcp";
    networking.firewall.allowedUDPPorts = firewallPortsForProtocol "udp";

    users.manageLingering = lib.mkIf (rootlessStackUsers != []) (lib.mkDefault true);
    users.users = lib.listToAttrs (map (user: {
        name = user;
        value.linger = lib.mkDefault true;
      })
      rootlessStackUsers);

    systemd = {
      tmpfiles.rules = lib.concatLists (
        lib.mapAttrsToList
        (_: stack: [
          "d ${stack.stackDir} 0750 ${stack.user} ${stackTmpfilesGroup stack} -"
        ])
        cfg
      );

      user.services = lib.listToAttrs (
        (map
          (s: {
            name = s.systemdServiceName;
            value = s.systemdService;
          })
          resolvedServices)
        ++ lib.concatMap (s: s.auxiliarySystemdUserServices) resolvedServices
        ++ map mkRootlessIdmapMigrateUserService rootlessStackUsersWithConfig
      );

      user.targets = lib.listToAttrs (
        lib.concatMap (s: s.auxiliarySystemdUserTargets) resolvedServices
        ++ map mkManagedUserTarget stackUsers
        ++ map mkManagedReadyUserTarget stackUsers
      );
    };

    assertions =
      [
        {
          assertion = duplicateSystemdUserServiceNames == [];
          message = "services.podman-compose: duplicate generated systemd.user service names: ${lib.concatStringsSep ", " duplicateSystemdUserServiceNames}";
        }
        {
          assertion = duplicateSystemdUserTargetNames == [];
          message = "services.podman-compose: duplicate generated systemd.user target names: ${lib.concatStringsSep ", " duplicateSystemdUserTargetNames}";
        }
        {
          assertion = duplicatedSubnets == [];
          message = "services.podman-compose: duplicate declared subnet values: ${lib.concatStringsSep ", " (map describeSubnetEntry duplicatedSubnetEntries)}";
        }
        {
          assertion = duplicatedExposedPortKeys == [];
          message = "services.podman-compose: duplicate exposed host ports: ${lib.concatStringsSep ", " (map describeExposedPortEntry duplicatedExposedPortEntries)}";
        }
        {
          assertion = reservedGeneratedPathViolations == [];
          message =
            "services.podman-compose: user-declared files/dirs must not target generated runtime paths "
            + "${generatedRuntimeDirName}/, ${envSecretsOverrideFileName}, or ${fileSecretsOverrideFileName}: "
            + lib.concatStringsSep ", " reservedGeneratedPathViolations;
        }
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.source != null || service.files != {};
            message = "services.podman-compose.${stackName}.instances.${serviceName}: set source and/or files.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.entryFile != null || builtins.length service.implicitEntryFileCandidates <= 1;
            message =
              "services.podman-compose.${stackName}.instances.${serviceName}: multiple default compose files are staged; set entryFile explicitly to declare compose file order: "
              + lib.concatStringsSep ", " service.implicitEntryFileCandidates;
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.imageTag == "0" || service.hasComposeEntry;
            message = "services.podman-compose.${stackName}.instances.${serviceName}: imageTag requires source or entryFile so image-pull can use store-backed compose files without staging runtime files.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.invalidReloadOnChangeDirs == [];
            message =
              "services.podman-compose.${stackName}.instances.${serviceName}.reload.trigger.dirs contains entries that are not declared dirs or directory sources: "
              + lib.concatStringsSep ", " service.invalidReloadOnChangeDirs;
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.reload.method != "signal" || service.reload.services != [];
            message = "services.podman-compose.${stackName}.instances.${serviceName}.reload.services must list compose services when reload.method = \"signal\" so reload does not signal every container accidentally.";
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.invalidReloadExternalFiles == [];
            message =
              "services.podman-compose.${stackName}.instances.${serviceName}.reload.trigger.externalFiles contains entries that are not declared staged files: "
              + lib.concatStringsSep ", " service.invalidReloadExternalFiles;
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.invalidRecreateTriggerFiles == [];
            message =
              "services.podman-compose.${stackName}.instances.${serviceName}.recreate.trigger.files contains entries that are not declared staged files: "
              + lib.concatStringsSep ", " service.invalidRecreateTriggerFiles;
          })
          stack.instances)
        cfg
      )
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.mapAttrsToList
          (serviceName: service: {
            assertion = service.conflictingReloadRecreateFiles == [];
            message =
              "services.podman-compose.${stackName}.instances.${serviceName}.reload.trigger contains recreate-class staged files, which are unsafe for native Podman reload because the container can keep stale runtime shape until container recreation: "
              + lib.concatStringsSep ", " service.conflictingReloadRecreateFiles;
          })
          stack.instances)
        cfg
      )
      ++ map (user: {
        assertion = builtins.hasAttr user config.users.users && config.users.users.${user}.uid != null;
        message = "services.podman-compose: rootless stack user '${user}' must exist in users.users with a non-null uid.";
      })
      rootlessStackUsers
      ++ map (user: {
        assertion = builtins.hasAttr user config.users.users && config.users.users.${user}.home != null;
        message = "services.podman-compose: rootless stack user '${user}' must have users.users.${user}.home set.";
      })
      rootlessStackUsers
      ++ lib.concatLists (
        lib.mapAttrsToList
        (stackName: stack:
          lib.concatMap
          (serviceName:
            lib.mapAttrsToList
            (fileName: entry: {
              assertion = (entry.text != null && entry.source == null) || (entry.text == null && entry.source != null);
              message = "services.podman-compose.${stackName}.instances.${serviceName}.files.${fileName}: set exactly one of text or source.";
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
            message = "services.podman-compose.${stackName}.instances.${serviceName}: auto-mounted fileSecrets require source or entryFile so podman compose can include the generated override file.";
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
            message = "services.podman-compose.${stackName}.instances.${serviceName}: envSecrets requires source or entryFile so podman compose can include the generated override file.";
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
              message = "services.podman-compose.${stackName}.instances.${serviceName}.envSecrets.${composeServiceName}: set at least one environment secret.";
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
            message = "services.podman-compose.${stackName}.instances.${serviceName}: entryFile '${describeEntryFile service.entryFile}' is not defined in source/files.";
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
              ownerOk = entry.scope == "host" || (isOwnerNumeric entry.user && isOwnerNumeric entry.group);
            in {
              assertion = ownerOk;
              message = "services.podman-compose.${stackName}.instances.${serviceName}.${kind}.${name}: scope = \"container\" requires numeric user and group when owner fields are set (userns has no name resolution).";
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
              message = "services.podman-compose.${stackName}.instances.${serviceName}.dirs.${dirName}.mode must be an octal directory mode with at least one execute/search bit.";
            })
            stack.instances.${serviceName}.dirs)
          (builtins.attrNames stack.instances))
        cfg
      );
  };
}
