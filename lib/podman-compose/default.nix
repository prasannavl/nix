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
  serviceDefaults = {
    source = null;
    files = {};
    entryFile = null;
    user = null;
    workingDir = null;
    serviceName = null;
    serviceOverrides = {};
    composeArgs = [];
    reload = {
      method = "restart";
      signal = "HUP";
      services = [];
      trigger = {
        dirs = [];
        externalFiles = [];
      };
    };
    subnet = null;
    autoStart = true;
    longRunning = true;
    timeoutStableSeconds = 120;
    recreateOnSwitch = false;
    bootTag = "0";
    reloadTag = "0";
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
  generatedRuntimeDirName = ".podman-compose";
  envSecretsRuntimeDirName = "${generatedRuntimeDirName}/env-secrets";
  fileSecretsRuntimeDirName = "${generatedRuntimeDirName}/file-secrets";
  envSecretsOverrideFileName = "__podman-env-secrets.override.yml";
  fileSecretsOverrideFileName = "__podman-file-secrets.override.yml";
  explicitSystemdUnitPattern = ".*\\.(service|target|socket|timer|path|mount)$";

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
        description = "Paths that may be handled by native reload instead of restart once the user-manager supports reload triggers.";
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
  stackTmpfilesGroup = stack:
    if builtins.hasAttr stack.user config.users.users && config.users.users.${stack.user}.group != null
    then config.users.users.${stack.user}.group
    else "-";

  helperPackage = pkgs.writeShellApplication {
    name = "podman-compose-helper";
    excludeShellChecks = ["SC1091"];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.podman
      pkgs.systemd
      pkgs.util-linux
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
        default = serviceDefaults.source;
        description = "Main compose source content. Attrsets are rendered to YAML; strings are copied as-is; paths are used directly.";
      };

      files = lib.mkOption {
        type = lib.types.attrsOf fileEntryType;
        default = serviceDefaults.files;
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
        default = serviceDefaults.dirs;
        description = ''
          Managed staged directories keyed by destination path. Relative paths
          are resolved under the compose working directory; absolute paths are
          managed directly on the host. Each entry carries mode/user/group/userScope,
          and is finalized after file staging so directory bind mounts can avoid
          world traversal bits. The helper runs as the stack user, so absolute
          path parents must already exist and be searchable/writable by that user.
        '';
      };

      entryFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.str (lib.types.listOf lib.types.str)]);
        default = serviceDefaults.entryFile;
        description = "Optional compose entry filename(s) inside workingDir. Set a string for one file or a list for ordered repeated `-f` arguments. When null and source is set, `compose.yml` in workingDir is used; otherwise podman compose default file discovery is used in workingDir.";
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

      reload = lib.mkOption {
        type = reloadType;
        default = serviceDefaults.reload;
        description = "Reload policy for this compose instance. Restart is the default; native signal reload is opt-in and only supports directory-mounted change sets.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.autoStart;
        description = "Whether this compose instance should be auto-started by the generated user-manager reconcile flow during deploy and boot-ready startup.";
      };

      longRunning = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.longRunning;
        description = "Whether this compose instance is expected to keep at least one container running. When false, all containers exiting cleanly is service success.";
      };

      timeoutStableSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = serviceDefaults.timeoutStableSeconds;
        description = "Seconds the generated user-manager reconciliation should wait for this compose unit to leave activating, deactivating, or reloading states.";
      };

      recreateOnSwitch = lib.mkOption {
        type = lib.types.bool;
        default = serviceDefaults.recreateOnSwitch;
        description = "Whether service starts triggered by switch/restart should force container recreation instead of reusing existing compose containers.";
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
        description = "Declarative knob to reload this compose instance through systemd-user-manager reloadTriggers when native reload is enabled.";
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

                  proxyBufferSize = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx proxy_buffer_size override for this route when upstream response headers are larger than nginx's default buffer.";
                  };

                  clientMaxBodySize = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Optional nginx client_max_body_size override for uploads to this route.";
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

      timeoutStableSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = serviceDefaults.timeoutStableSeconds;
        description = "Default stable-state wait timeout, in seconds, for compose instances in this stack. Instances can override this with their own timeoutStableSeconds.";
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
      else if builtins.match explicitSystemdUnitPattern dep != null
      then dep
      else "${stack.servicePrefix}${dep}.service";

    dependsOnUnits = lib.unique (map resolveDependencyUnit service.dependsOn);
    wantsUnits = lib.unique (map resolveDependencyUnit service.wants);
    networkOnlineUnits = lib.optional service.waitForNetwork "network-online.target";

    imagePullServiceName = "${resolvedSystemdServiceName}-image-pull";
    imagePullUnit = "${imagePullServiceName}.service";
    hasImagePullUnit = service.imageTag != "0";
    resolvedPullComposeFiles = map (file: service.sourcePaths.${file}) service.pullEntryFiles;
    nativeReloadEnabled = service.reload.method == "signal";
    reloadPathMatchesDir = dirName: fileName:
      fileName == dirName || lib.hasPrefix "${dirName}/" fileName;
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
            (dirName: reloadPathMatchesDir dirName fileName)
            service.reload.trigger.dirs
        )
        service.stagedEntries
      else {};
    restartStagedEntries =
      lib.filterAttrs
      (fileName: _: !(builtins.hasAttr fileName reloadStagedEntries))
      service.stagedEntries;
    restartRuntimePaths =
      lib.filterAttrs
      (fileName: _: !(builtins.hasAttr fileName reloadStagedEntries))
      service.runtimePaths;
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
      scope = entry.userScope;
    };
    helperMetadata = pkgs.writeText "podman-compose-${resolvedSystemdServiceName}.json" (
      builtins.toJSON {
        version = 5;
        serviceName = resolvedSystemdServiceName;
        workingDir = resolvedWorkingDir;
        composeArgs = service.composeArgs;
        composeFiles = resolvedComposeFiles;
        pullComposeFiles = resolvedPullComposeFiles;
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
        reload = {
          inherit (service.reload) method signal services;
          dirs =
            map (dirName: {
              name = dirName;
              dst = reloadDirRuntimePath dirName;
            })
            service.reload.trigger.dirs;
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
        recreateOnSwitch = service.recreateOnSwitch;
        recreateTag = service.recreateTag;
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
            "NIX_PODMAN_COMPOSE_IMAGE_TAG=${service.imageTag}"
          ];
        WorkingDirectory = "-${resolvedWorkingDir}";
        ExecStart = "${helperScript} image-pull";
        TimeoutStartSec = 900;
      };
    };
    mergedSystemdService = lib.recursiveUpdate baseSystemdService service.serviceOverrides;
    restartSystemdService =
      mergedSystemdService
      // {
        serviceConfig =
          mergedSystemdService.serviceConfig
          // {
            Environment =
              map
              (env:
                if lib.hasPrefix "NIX_PODMAN_COMPOSE_METADATA=" env
                then "NIX_PODMAN_COMPOSE_METADATA=<generation-local-metadata>"
                else env)
              mergedSystemdService.serviceConfig.Environment;
          };
      };
    reloadStamp =
      if nativeReloadEnabled
      then
        builtins.hashString "sha256" (builtins.toJSON {
          reload = service.reload;
          reloadTag = service.reloadTag;
          dirs =
            map (dirName: {
              name = dirName;
              dst = reloadDirRuntimePath dirName;
              perms =
                if builtins.hasAttr dirName service.dirs
                then entryPermsJson service.dirs.${dirName}
                else null;
            })
            service.reload.trigger.dirs;
          sourcePaths = lib.mapAttrs (fileName: _: service.sourcePaths.${fileName}) reloadStagedEntries;
          runtimePaths = lib.mapAttrs (fileName: _: service.runtimePaths.${fileName}) reloadStagedEntries;
          stagedEntryPerms =
            lib.mapAttrs (_: entryPermsJson) reloadStagedEntries;
        })
      else "";
  in {
    systemdServiceName = resolvedSystemdServiceName;
    systemdUser = resolvedUser;
    systemdService = mergedSystemdService;
    auxiliarySystemdUserServices = lib.optional hasImagePullUnit {
      name = imagePullServiceName;
      value = imagePullSystemdService;
    };
    restartStamp = builtins.hashString "sha256" (builtins.toJSON {
      unit = restartSystemdService;
      reload = service.reload;
      sourcePaths = lib.mapAttrs (fileName: _: service.sourcePaths.${fileName}) restartStagedEntries;
      runtimePaths = restartRuntimePaths;
      dirs = lib.mapAttrs (_: entryPermsJson) service.dirs;
      dirRuntimePaths = service.dirRuntimePaths;
      stagedEntryPerms =
        lib.mapAttrs (_: entryPermsJson) restartStagedEntries;
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
    reloadStamp = reloadStamp;
    inherit (service) autoStart longRunning timeoutStableSeconds imageTag recreateTag bootTag reloadTag waitForNetwork;
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
  duplicatedExposedPortKeys = collectionsLib.duplicateValues (map (entry: entry.key) allExposedPortEntries);
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
    resolvedServices;
  duplicateSystemdUserServiceNames = collectionsLib.duplicateValues generatedSystemdUserServiceNames;
  rootlessStackUsers = lib.unique (
    builtins.filter (user: user != "root") (
      map (service: service.systemdUser) resolvedServices
    )
  );
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
  rootlessIdmapMigrateServiceNameForUser = user: "podman-rootless-idmap-migrate-${serviceNameUserKey user}";
  dispatcherServiceNameForUser = user: "systemd-user-manager-dispatcher-${serviceNameUserKey user}";
  # Rootless Podman can keep a stale single-id namespace after subuid/subgid
  # ranges appear; migrate before compose starts so container ids can map.
  mkRootlessIdmapMigrateService = user: let
    userCfg = config.users.users.${user};
    uid = toString userCfg.uid;
    home = userCfg.home;
    serviceName = rootlessIdmapMigrateServiceNameForUser user;
    dispatcherServiceName = dispatcherServiceNameForUser user;
    networkOnlineUnits = rootlessStackUserNetworkOnlineUnits user;
    script = pkgs.writeShellScript "${serviceName}-script" ''
      set -eu

      user=${lib.escapeShellArg user}

      has_subid_range() {
        ${pkgs.gawk}/bin/awk -F: -v user="$user" '
          $1 == user && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
            found = 1
          }
          END {
            exit found ? 0 : 1
          }
        ' "$1"
      }

      if ! has_subid_range /etc/subuid || ! has_subid_range /etc/subgid; then
        echo "podman rootless idmap: no subordinate uid/gid range for $user; skipping migration"
        exit 0
      fi

      idmap_json="$(${pkgs.podman}/bin/podman info --format json)"
      uidmap_count="$(printf '%s\n' "$idmap_json" | ${pkgs.jq}/bin/jq -r '(.host.idMappings.uidmap // []) | length')"
      gidmap_count="$(printf '%s\n' "$idmap_json" | ${pkgs.jq}/bin/jq -r '(.host.idMappings.gidmap // []) | length')"

      if [ "$uidmap_count" -le 1 ] || [ "$gidmap_count" -le 1 ]; then
        echo "podman rootless idmap: stale single-id map for $user; running podman system migrate"
        ${pkgs.podman}/bin/podman system migrate
      else
        echo "podman rootless idmap: subordinate uid/gid map already active for $user"
      fi
    '';
  in {
    name = serviceName;
    value = {
      description = "Reconcile rootless Podman uid/gid map for ${user}";
      after = networkOnlineUnits ++ ["user@${uid}.service"];
      before = ["${dispatcherServiceName}.service"];
      wants = networkOnlineUnits ++ ["user@${uid}.service"];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Environment = [
          "HOME=${home}"
          "XDG_RUNTIME_DIR=/run/user/${uid}"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus"
          "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        ];
        ExecStart = script;
      };
    };
  };
  mkDispatcherRootlessIdmapDependency = user: let
    serviceName = rootlessIdmapMigrateServiceNameForUser user;
    dispatcherServiceName = dispatcherServiceNameForUser user;
    networkOnlineUnits = rootlessStackUserNetworkOnlineUnits user;
  in {
    name = dispatcherServiceName;
    value = {
      after = networkOnlineUnits ++ ["${serviceName}.service"];
      wants = networkOnlineUnits;
      requires = ["${serviceName}.service"];
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
  duplicatedSubnets = collectionsLib.duplicateValues (map (entry: entry.subnet) declaredSubnets);
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
            match = builtins.match "[[:space:]]*-[[:space:]]*([^:#]+):.*" line;
          in
            if match == null
            then []
            else [(stripVolumeSourceQuotes (builtins.head match))])
          (lib.splitString "\n" text);
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
              baseService =
                serviceDefaults
                // {
                  timeoutStableSeconds = stack.timeoutStableSeconds;
                }
                // service;
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
              normalizedEntryFile =
                if generatedOverrideFiles == []
                then normalizedService.entryFile
                else baseEntryFiles ++ generatedOverrideFiles;
              filesExpanded =
                lib.concatMapAttrs (dstPath: entry: expandFileEntry dstPath entry) normalizedService.files;
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
              effectiveEntries =
                (lib.optionalAttrs useSource {"compose.yml" = mkGeneratedEntry sourceCompose;})
                // filesExpanded
                // (lib.optionalAttrs (envSecretsOverride != {}) {"${envSecretsOverrideFileName}" = mkGeneratedEntry envSecretsOverride;})
                // (lib.optionalAttrs (fileSecretsOverride != {}) {"${fileSecretsOverrideFileName}" = mkGeneratedEntry fileSecretsOverride;});
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
              bindMountedReloadExternalFiles =
                lib.filter
                (fileName: builtins.elem fileName composeBindSources)
                normalizedService.reload.trigger.externalFiles;
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
            in
              normalizedService
              // {
                resolvedWorkingDir = resolvedWorkingDir;
                hasComposeEntry = hasComposeEntry;
                fileSecretRuntimePaths = fileSecretRuntimePaths;
                dirRuntimePaths = dirRuntimePaths;
                envSecretRuntimePaths = envSecretRuntimePaths;
                stagedEntries = effectiveEntries;
                sourcePaths = sourcePaths;
                runtimePaths = lib.mapAttrs (fileName: _: "${resolvedWorkingDir}/${fileName}") effectiveEntries;
                entryFile = normalizedEntryFile;
                pullEntryFiles = baseEntryFiles;
                userDeclaredRuntimePaths = (builtins.attrNames filesExpanded) ++ (builtins.attrNames normalizedService.dirs);
                validReloadOnChangeDirs = validReloadOnChangeDirs;
                invalidReloadOnChangeDirs = invalidReloadOnChangeDirs;
                invalidReloadExternalFiles = invalidReloadExternalFiles;
                bindMountedReloadExternalFiles = bindMountedReloadExternalFiles;
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
      );

      services = lib.mkMerge [
        (lib.listToAttrs (map mkRootlessIdmapMigrateService rootlessStackUsersWithConfig))
        (lib.listToAttrs (map mkDispatcherRootlessIdmapDependency rootlessStackUsersWithConfig))
      ];
    };

    assertions =
      [
        {
          assertion = duplicateSystemdUserServiceNames == [];
          message = "services.podmanCompose: duplicate generated systemd.user service names: ${lib.concatStringsSep ", " duplicateSystemdUserServiceNames}";
        }
        {
          assertion = duplicatedSubnets == [];
          message = "services.podmanCompose: duplicate declared subnet values: ${lib.concatStringsSep ", " (map describeSubnetEntry duplicatedSubnetEntries)}";
        }
        {
          assertion = duplicatedExposedPortKeys == [];
          message = "services.podmanCompose: duplicate exposed host ports: ${lib.concatStringsSep ", " (map describeExposedPortEntry duplicatedExposedPortEntries)}";
        }
        {
          assertion = reservedGeneratedPathViolations == [];
          message =
            "services.podmanCompose: user-declared files/dirs must not target generated runtime paths "
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
            assertion = service.imageTag == "0" || service.hasComposeEntry;
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: imageTag requires source or entryFile so image-pull can use store-backed compose files without staging runtime files.";
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
              "services.podmanCompose.${stackName}.instances.${serviceName}.reload.trigger.dirs contains entries that are not declared dirs or directory sources: "
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
            message = "services.podmanCompose.${stackName}.instances.${serviceName}.reload.services must list compose services when reload.method = \"signal\" so reload does not signal every container accidentally.";
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
              "services.podmanCompose.${stackName}.instances.${serviceName}.reload.trigger.externalFiles contains entries that are not declared staged files: "
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
            assertion = service.bindMountedReloadExternalFiles == [];
            message =
              "services.podmanCompose.${stackName}.instances.${serviceName}.reload.trigger.externalFiles contains single-file bind mounts, which are unsafe for native Podman reload because the container can keep the old mounted inode until restart: "
              + lib.concatStringsSep ", " service.bindMountedReloadExternalFiles;
          })
          stack.instances)
        cfg
      )
      ++ map (user: {
        assertion = builtins.hasAttr user config.users.users && config.users.users.${user}.uid != null;
        message = "services.podmanCompose: rootless stack user '${user}' must exist in users.users with a non-null uid.";
      })
      rootlessStackUsers
      ++ map (user: {
        assertion = builtins.hasAttr user config.users.users && config.users.users.${user}.home != null;
        message = "services.podmanCompose: rootless stack user '${user}' must have users.users.${user}.home set.";
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
            message = "services.podmanCompose.${stackName}.instances.${serviceName}: entryFile '${describeEntryFile service.entryFile}' is not defined in source/files.";
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

    services.systemdUserManager.instances = lib.listToAttrs (map
      (s: {
        name = s.systemdServiceName;
        value = {
          user = s.systemdUser;
          unit = "${s.systemdServiceName}.service";
          autoStart = s.autoStart;
          timeoutStableSeconds = s.timeoutStableSeconds;
          restartTriggers = [
            s.restartStamp
            s.recreateTag
            s.bootTag
          ];
          reloadTriggers = lib.optionals (s.reloadStamp != "") [
            s.reloadStamp
            s.reloadTag
          ];
          stampPayload =
            {
              kind = "podman-managed-unit";
              restartStamp = s.restartStamp;
              recreateTag = s.recreateTag;
              bootTag = s.bootTag;
              reloadTag = s.reloadTag;
              reloadCapable = s.reloadStamp != "";
            }
            // lib.optionalAttrs (s.systemdUser != "root" && s.waitForNetwork) {
              rootlessNetworkReadiness = "network-online-before-rootless-netns-v1";
            };
        };
      })
      resolvedServices);
  };
}
