{
  config,
  lib,
  pkgs,
  ...
}: let
  manager = config.services.abird-host-manager;
  controller = manager.buildController;
  cfg = controller.capture;
  account = name: config.users.users.${name};
  groups = name:
    lib.unique ([(account name).group]
      ++ (account name).extraGroups
      ++ lib.attrNames (lib.filterAttrs (_: group: lib.elem name group.members) config.users.groups));
  state = "${cfg.xdgStateHome}/abird/abird-host-manager/owned-capture";
  program = "${manager.package}/libexec/abird-host-manager";
  narConfiguration = pkgs.writeTextDir "nix.conf" "experimental-features = nix-command flakes\n";
  # Follow the declared /bin/sh backing package, not the ambient system PATH.
  # linkFarm preserves its store reference without inspecting the live host.
  runtimeShell = pkgs.linkFarm "abird-owned-capture-runtime-shell" (lib.optional (config.environment.binsh != null) {
    name = "sh";
    path = config.environment.binsh;
  });
  runtimeClosure = pkgs.closureInfo {
    # NixOS's ordinary cat/env come from coreutils-full; fixed tools may also
    # reference coreutils. Exact-inode scopes must cover both output identities.
    rootPaths = [manager.package cfg.gitPackage config.nix.package narConfiguration runtimeShell pkgs.bashNonInteractive pkgs.coreutils pkgs.coreutils-full config.i18n.glibcLocales] ++ cfg.runtimePackages;
  };
  policy = {
    version = 1;
    state = state;
    manager = program;
    git = "${cfg.gitPackage}/bin/git";
    nar = "${config.nix.package}/bin/nix-store";
    nar_configuration = toString narConfiguration;
    runtime_closure = "${runtimeClosure}/store-paths";
    systemctl = "${config.systemd.package}/bin/systemctl";
    relay_key = cfg.relayKeyFile;
    relay_user = cfg.relayUser;
    relay_port = cfg.relayPort;
    max_seconds = cfg.maxSeconds;
    retention_seconds = cfg.retentionSeconds;
    limits = cfg.sourceLimits;
    callers = lib.mapAttrs' (name: caller:
      lib.nameValuePair (toString (account name).uid) {
        bootstrap = toString controller.callerBootstraps.${name};
        account = {
          user = name;
          uid = (account name).uid;
          gid = config.users.groups.${(account name).group}.gid;
          home = (account name).home;
          state_home = caller.stateHome;
          capture_roots = caller.roots;
          groups = lib.sort builtins.lessThan (lib.unique (map (group: config.users.groups.${group}.gid) (groups name)));
        };
      })
    cfg.callers;
  };
  absolute = path: lib.hasPrefix "/" path && !(lib.elem ".." (lib.splitString "/" path));
  common = {
    User = "root";
    Group = "root";
    Restart = "no";
    UMask = "0077";
    LimitCORE = 0;
    StandardOutput = "null";
    StandardError = "null";
  };
in {
  options.services.abird-host-manager.buildController.capture = {
    enable = lib.mkEnableOption "admitted caller-only capture (no build executor or scheduler)";
    callers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          stateHome = lib.mkOption {
            type = lib.types.str;
            description = "Original caller absolute XDG state home.";
          };
          roots = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Explicit caller source roots; not whole homes.";
          };
        };
      });
      default = {};
      description = "Existing accounts with installed caller bootstrap and capture authority.";
    };
    relayUser = lib.mkOption {
      type = lib.types.str;
      description = "Builder input-only SSH login, distinct from ordinary control principal.";
    };
    relayPort = lib.mkOption {
      type = lib.types.ints.between 1 65535;
      default = 2022;
      description = "Explicit admitted input-only builder SSH port, distinct from ordinary control SSH; host trust remains pinned to that builder.";
    };
    relayKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only runtime SSH key reference; never key contents or a store path.";
    };
    xdgStateHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib";
      description = "Absolute root service XDG state base.";
    };
    gitPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.git;
      description = "Pinned native caller Git executable.";
    };
    runtimePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Explicit offline helper dependencies beyond fixed manager/Git/Nix/shell/coreutils runtimes. The configured /bin/sh backing package is included, but ambient system PATH packages are not. Undeclared helper dependencies fail closed under the unchanged bounded exact-inode read scope.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Approved capture aggregate byte limit.";
    };
    tasksMax = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Approved capture aggregate task limit.";
    };
    cpuPercent = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Approved aggregate CPU quota in percent.";
    };
    maxSeconds = lib.mkOption {
      type = lib.types.ints.between 1 86400;
      description = "Maximum unit lifetime; original builder cutoff may be earlier.";
    };
    retentionSeconds = lib.mkOption {
      type = lib.types.ints.between 60 86400;
      default = 600;
      description = "Finite settled capture metadata retention after the last accepted replay window; unresolved evidence is never discarded by age.";
    };
    sourceLimits = lib.mkOption {
      type = lib.types.submodule {
        options = {
          entries = lib.mkOption {type = lib.types.ints.positive;};
          bytes = lib.mkOption {type = lib.types.ints.positive;};
          depth = lib.mkOption {type = lib.types.ints.positive;};
        };
      };
      description = "Approved finite source capture limits; not wire representation limits.";
    };
  };
  config = lib.mkIf (controller.enable && cfg.enable) {
    # Fixed trusted transport uses the root-controlled system PATH, not caller PATH.
    environment.systemPackages = [pkgs.openssh];
    assertions = [
      {
        assertion = config.environment.binsh != null && lib.hasPrefix "/nix/store/" (toString config.environment.binsh);
        message = "Offline capture requires a declared immutable environment.binsh backing executable; no ambient shell dependency fallback.";
      }
      {
        assertion = !(lib.attrByPath ["services" "abird-host-agent" "buildExecutor" "enable"] false config);
        message = "Caller capture-only role is separate from the builder executor; colocated capture uses the existing executor.";
      }
      {
        assertion =
          cfg.callers
          != {}
          && builtins.length (lib.attrNames cfg.callers) <= 16
          && lib.all (name:
            builtins.hasAttr name controller.callerBootstraps
            && (account name).uid != null
            && (account name).uid > 0
            && absolute cfg.callers.${name}.stateHome
            && cfg.callers.${name}.roots != []
            && lib.all absolute cfg.callers.${name}.roots
            && lib.all (group: config.users.groups.${group}.gid != null && config.users.groups.${group}.gid > 0) (groups name)) (lib.attrNames cfg.callers);
        message = "Capture callers require existing UID/GIDs, immutable bootstraps and explicit absolute source/state roots.";
      }
      {
        assertion = absolute cfg.xdgStateHome && absolute cfg.relayKeyFile && !(lib.hasPrefix "/nix/store/" cfg.relayKeyFile);
        message = "Capture state/key references must be absolute; relay secrets must not enter the Nix store.";
      }
    ];
    environment.etc."abird-owned-capture.json".source = pkgs.writeText "abird-owned-capture.json" (builtins.toJSON policy);
    systemd = {
      tmpfiles.rules = [
        "d ${cfg.xdgStateHome}/abird 0755 root root -"
        "d ${cfg.xdgStateHome}/abird/abird-host-manager 0755 root root -"
        "d ${state} 0700 root root -"
        "d /run/abird-owned-capture 0755 root root -"
      ];
      # Same process-placement boundary, but no native daemon or build executor.
      slices = {
        abird.description = "Abird workloads";
        abird-build = {
          description = "Admitted caller capture only";
          sliceConfig = {
            MemoryMax = cfg.memoryMax;
            MemorySwapMax = 0;
            TasksMax = cfg.tasksMax;
            CPUQuota = "${toString cfg.cpuPercent}%";
          };
        };
      };
      sockets.abird-owned-capture-control = {
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = "/run/abird-owned-capture/control";
          SocketMode = "0666";
          Accept = true;
          MaxConnections = 4;
        };
      };
      timers.abird-owned-capture-reap = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "1min";
          AccuracySec = "10s";
        };
      };
      services = {
        "abird-owned-capture@" = {
          description = "Original admitted caller capture %i";
          unitConfig.CollectMode = "inactive-or-failed";
          serviceConfig =
            common
            // {
              Type = "exec";
              ExecStart = "${program} _owned-capture-worker %i";
              Slice = "abird-build.slice";
              Delegate = true;
              KillMode = "control-group";
              RuntimeMaxSec = cfg.maxSeconds;
              TimeoutStopSec = 10;
              # Root wrapper makes private mount/PID/IPC and producer subgroups; only
              # fixed unprivileged offline children ever execute caller helpers.
              PrivateTmp = true;
            };
          environment = {
            HOME = "/var/empty";
            XDG_STATE_HOME = cfg.xdgStateHome;
          };
        };
        abird-owned-capture-reap = {
          description = "Bounded settled caller capture retirement";
          serviceConfig =
            common
            // {
              Type = "oneshot";
              ExecStart = "${program} _owned-capture-reap";
              Slice = "abird-build.slice";
              TimeoutStartSec = 30;
              TimeoutStopSec = 5;
              KillMode = "control-group";
            };
        };
        # Separate socket handler template: it must not share the worker identity.
        "abird-owned-capture-control@" = {
          description = "Bounded capture control connection";
          serviceConfig =
            common
            // {
              ExecStart = "${program} _owned-capture-control";
              StandardInput = "socket";
              RuntimeMaxSec = 10;
              MemoryMax = 67108864;
              TasksMax = 16;
              RestrictAddressFamilies = ["AF_UNIX"];
            };
        };
      };
    };
  };
}
