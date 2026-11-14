{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.abird-host-agent.buildExecutor;
  agentPackage = config.services.abird-host-agent.package;
  manager = config.services.abird-host-manager;
  fleet = manager.buildController;
  controllerStateHomes =
    if fleet.enable
    then fleet.controllerStateHomes
    else {};
  captureRoots =
    if fleet.enable
    then fleet.captureRoots
    else {};
  nativePackage = config.nix.package;
  consumer = controllerStateHomes != {};
  consumerUnits = ["abird-owned-consumer@.service" "abird-owned-consumer.socket"];
  publisher = lib.attrByPath ["services" "harmonia" "cache" "enable"] false config;
  # Normalize configuration subpaths through a store object: closureInfo roots
  # are output roots, while gitConfiguration may name a file within an output.
  runtimeConfiguration = pkgs.linkFarm "abird-owned-runtime-config" ([
      {
        name = "native";
        path = nativeConfiguration;
      }
      {
        name = "gitconfig";
        path = cfg.gitConfiguration;
      }
    ]
    ++ lib.optional (config.environment.binsh != null) {
      name = "sh";
      path = config.environment.binsh;
    });
  runtimeClosure = pkgs.closureInfo {
    # No ambient system PATH closure: bounded exact-inode inventory would spend
    # the source budget on unrelated tools. coreutils-full backs ordinary cat/env.
    rootPaths = [manager.package cfg.gitPackage nativePackage runtimeConfiguration pkgs.bashNonInteractive pkgs.coreutils pkgs.coreutils-full config.i18n.glibcLocales] ++ cfg.runtimePackages;
  };
  stateParent = "${cfg.xdgStateHome}/abird/abird-host-agent";
  authority = "${stateParent}/owned-build";
  dataParent = "${cfg.xdgDataHome}/abird/abird-host-agent/owned-build";
  sources = "${dataParent}/sources";
  rolePath = "/etc/abird-owned-build/role.json";
  daemonPath = "/etc/abird-owned-build/daemon.json";
  controlPath = "/etc/abird-owned-build/control.json";
  agent = "${agentPackage}/bin/abird-host-agent";
  inputSshConfiguration = pkgs.writeText "abird-owned-input-sshd.conf" ''
    UsePAM no
    UseDNS no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    PermitRootLogin no
    PermitUserEnvironment no
    PermitUserRC no
    PermitTTY no
    DisableForwarding yes
    X11Forwarding no
    MaxSessions 1
    MaxAuthTries 3
    LoginGraceTime 10
    ClientAliveInterval 2
    ClientAliveCountMax 2
    Compression no
    PidFile none
    LogLevel QUIET
    AuthorizedKeysCommand none
    AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
    AllowUsers ${lib.concatStringsSep " " (lib.attrNames cfg.inputPrincipals)}
    ForceCommand abird-owned-input
    ${lib.concatMapStringsSep "\n" (key: "HostKey ${key.path}") config.services.openssh.hostKeys}
  '';
  sourceUser = "abird-owned-source";
  readerUser = "abird-owned-builder";
  readerGroup = "abird-owned-readers";
  # NSS-visible membership: primary + extraGroups + groups listing the user
  # as a member (e.g. the control socket group). Must match runtime getgrouplist.
  memberGroups = name:
    lib.unique ([config.users.users.${name}.group]
      ++ config.users.users.${name}.extraGroups
      ++ lib.attrNames (lib.filterAttrs (_: group: lib.elem name group.members) config.users.groups));
  canonicalDigest = domain: value: builtins.hashString "sha256" (domain + "\n" + builtins.toJSON value);
  nativeConfiguration = pkgs.linkFarm "abird-owned-native-config" [
    {
      name = "nix.conf";
      path = config.environment.etc."nix/nix.conf".source;
    }
  ];
  unitNames =
    [
      "abird-owned-build-supervisor.service"
      "abird-build-client@.service"
      "abird-owned-build-bootstrap.service"
      "nix-daemon.service"
      "nix-daemon.socket"
      "abird-owned-build-control@.service"
      "abird-owned-build-control.socket"
      "abird.slice"
      "abird-build.slice"
      "abird-build-owned.slice"
      "abird-control.slice"
      "abird-owned-maintenance-request.service"
      "abird-owned-fleet@.service"
    ]
    ++ lib.optional publisher "harmonia.service"
    ++ lib.optional consumer "abird-build-consumer.slice";
  definition = name:
    (lib.optional (lib.elem name ["nix-daemon.service" "nix-daemon.socket"])
      "${nativePackage}/lib/systemd/system/${name}")
    ++ ["${config.systemd.units.${name}.unit}/${name}"];
  definitions = lib.genAttrs unitNames definition;
  role =
    (lib.optionalAttrs (cfg.inputPrincipals != {}) {
      input_principals = lib.mapAttrs' (_: principal: lib.nameValuePair principal.issuer principal.uid) cfg.inputPrincipals;
      input_transport = {
        sshd = "${config.services.openssh.package}/bin/sshd";
        configuration = toString inputSshConfiguration;
        host_keys = map (key: key.path) config.services.openssh.hostKeys;
        port = cfg.inputPort;
      };
    })
    // lib.optionalAttrs consumer {
      consumer.definitions = lib.genAttrs consumerUnits definition;
    }
    // {
      version = 2;
      manager_program = "${manager.package}/libexec/abird-host-manager";
      runtime_closure = "${runtimeClosure}/store-paths";
      publisher = publisher;
      systemctl = "${config.systemd.package}/bin/systemctl";
      daemon_policy = daemonPath;
      control = controlPath;
      input_gid = cfg.controlGid;
      definitions = definitions;
      limits = cfg.resources;
      control_limits = cfg.controlReserve;
      controller = {
        accounts = lib.mapAttrs' (name: stateHome:
          lib.nameValuePair cfg.principals.${name}.issuer {
            user = name;
            uid = cfg.principals.${name}.uid;
            gid = config.users.groups.${config.users.users.${name}.group}.gid;
            home = config.users.users.${name}.home;
            state_home = stateHome;
            capture_roots = captureRoots.${name} or [];
            groups =
              lib.sort builtins.lessThan (lib.unique (map (group: config.users.groups.${group}.gid)
                  (memberGroups name)));
          })
        controllerStateHomes;
      };
      build = {
        uid = cfg.readerUid;
        gid = cfg.readerGid;
        source_uid = cfg.sourceUid;
        source_user = sourceUser;
        git_program = "${cfg.gitPackage}/bin/git";
        git_configuration = toString cfg.gitConfiguration;
        source_limits = cfg.sourceLimits;
        repositories = cfg.repositories;
      };
    };
  buildUsers = lib.filterAttrs (_: user: user.group == config.nix.settings.build-users-group) config.users.users;
  controlBase = {
    version = 1;
    identity = cfg.identity;
    policy = {
      capacity_digest = lib.concatStrings (lib.replicate 64 "0");
      deadlines = cfg.deadlines;
      max_jobs = cfg.maxJobs;
      max_cores = cfg.maxCores;
      submission_age_seconds = cfg.submissionAgeSeconds;
      future_skew_seconds = cfg.futureSkewSeconds;
      replay_seconds = cfg.replaySeconds;
    };
    workload_uids = [cfg.readerUid cfg.sourceUid] ++ lib.mapAttrsToList (_: user: user.uid) buildUsers;
    principals = lib.mapAttrsToList (_: principal: principal) cfg.principals;
    timeout_millis = cfg.controlTimeoutMillis;
    allow_submit = cfg.acceptSubmissions;
  };
  native = {
    version = 7;
    containment_digest = canonicalDigest "abird-owned-role-v2" role;
    control_digest = canonicalDigest "abird-owned-control-binding-v1" controlBase;
    role_policy = rolePath;
    launcher = agent;
    program = "${nativePackage}/bin/nix-daemon";
    evaluation_library = "${manager.package}/libexec/libabird-owned-nix.so";
    system = config.nix.settings.system or pkgs.stdenv.hostPlatform.system;
    search_path = lib.makeBinPath [nativePackage cfg.gitPackage config.programs.ssh.package];
    configuration_directory = toString nativeConfiguration;
    certificate_bundle = toString config.security.pki.caBundle;
    clients = [
      {
        uid = cfg.readerUid;
        user = readerUser;
      }
    ];
  };
  control =
    controlBase
    // {
      policy =
        controlBase.policy
        // {
          capacity_digest = canonicalDigest "abird-owned-daemon-policy-v7" native;
        };
    };
  environment = {
    XDG_STATE_HOME = cfg.xdgStateHome;
    XDG_DATA_HOME = cfg.xdgDataHome;
    HOME = "/var/empty";
  };
  workPercent = builtins.div (100 * cfg.resources.cpu_quota_micros) cfg.resources.cpu_period_micros;
  controlService = {
    User = "root";
    Group = "root";
    Slice = "abird-control.slice";
    Restart = "no";
    UMask = "0077";
    LimitCORE = 0;
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [stateParent];
    RestrictAddressFamilies = ["AF_UNIX"];
    StandardOutput = "null";
    StandardError = "null";
  };
  absolute = value: builtins.match "/[a-zA-Z0-9_./-]+" value != null && !(lib.elem ".." (lib.splitString "/" value));
in {
  imports = [./control.nix ../../abird-host-manager];
  options.services.abird-host-agent.buildExecutor = import ./options.nix {inherit config lib pkgs;};

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.environment.binsh != null && lib.hasPrefix "/nix/store/" (toString config.environment.binsh);
        message = "Offline source helpers require a declared immutable environment.binsh backing executable; no ambient shell dependency fallback.";
      }
      {
        assertion =
          (manager.package.buildNativeAdapter or null)
          != null
          && toString (manager.package.buildNativeNix or "") == toString nativePackage;
        message = "Agent-managed preparation requires the manager adapter built against this exact config.nix.package.";
      }
      {
        assertion = config.nix.enable && config.nix.daemonUser == "root";
        message = "Agent-managed native execution requires the normal root daemon/build-user model.";
      }
      {
        assertion = !(config.nix.settings.auto-allocate-uids or false);
        message = "Agent-managed credentials require explicit, stable Nix build-user UIDs.";
      }
      {
        assertion = !config.nix.distributedBuilds && config.nix.buildMachines == [];
        message = "Unowned distributed-native producers are not supported by this executor.";
      }
      {
        assertion = !config.nix.sshServe.enable;
        message = "Unscoped native SSH-store ingress must be drained before owned enablement.";
      }
      {
        assertion = config.nix.extraOptions == "";
        message = "Agent-managed immutable Nix context requires typed settings, not external include/directive text.";
      }
      {
        assertion = absolute cfg.xdgStateHome && absolute cfg.xdgDataHome && cfg.xdgStateHome != cfg.xdgDataHome;
        message = "Agent-managed data and private authority require separate absolute XDG bases.";
      }
      {
        assertion = !(lib.hasPrefix "${authority}/" sources) && !(lib.hasPrefix "${sources}/" authority);
        message = "Agent-managed data and journal authorities must not contain each other.";
      }
      {
        assertion = lib.hasPrefix "/nix/store/" (toString cfg.gitConfiguration);
        message = "Agent-managed Git context must be an immutable store file; credentials remain out of the store.";
      }
      {
        assertion = cfg.sourceUid != cfg.readerUid && cfg.readerGid != cfg.controlGid;
        message = "Source/native/control credentials must remain distinct.";
      }
      {
        assertion = (100 * cfg.resources.cpu_quota_micros) == workPercent * cfg.resources.cpu_period_micros;
        message = "Agent-managed CPU limits must render exactly to systemd percentages.";
      }
      {
        assertion = cfg.resources.memory_high < cfg.resources.memory_max && cfg.resources.min_state_free_bytes >= 33554432;
        message = "Agent-managed work high/max and journal headroom are incomplete.";
      }
      {
        assertion = lib.all (name: config.users.users.${name}.uid == cfg.principals.${name}.uid) (lib.attrNames cfg.principals);
        message = "Agent-managed principals must bind existing account UIDs; no account/key fallback.";
      }
      {
        assertion =
          lib.all (name: let
            principal = cfg.inputPrincipals.${name};
          in
            config.users.users.${name}.uid
            == principal.uid
            && config.users.users.${name}.hashedPassword == "*"
            && config.users.users.${name}.hashedPasswordFile == null
            && !(builtins.hasAttr name cfg.principals)
            && lib.all (other: other == name || config.users.users.${other}.uid != principal.uid) (lib.attrNames config.users.users)
            && !(lib.elem principal.uid ([cfg.sourceUid cfg.readerUid]
              ++ map (p: p.uid) (lib.attrValues cfg.principals)
              ++ lib.mapAttrsToList (_: user: user.uid) buildUsers))
            && lib.elem principal.issuer (map (p: p.issuer) (lib.attrValues cfg.principals))) (lib.attrNames cfg.inputPrincipals)
          && builtins.length (lib.unique (map (p: p.uid) (lib.attrValues cfg.inputPrincipals))) == builtins.length (lib.attrNames cfg.inputPrincipals)
          && builtins.length (lib.unique (map (p: p.issuer) (lib.attrValues cfg.inputPrincipals))) == builtins.length (lib.attrNames cfg.inputPrincipals);
        message = "Input-only relays require distinct UIDs without aliases, password-disabled (*) non-PAM accounts and unique installed issuer bindings.";
      }
      {
        assertion = cfg.inputPrincipals == {} || (config.services.openssh.enable && !(lib.elem cfg.inputPort config.services.openssh.ports));
        message = "Admitted input SSH requires existing host-key provisioning and a port distinct from ordinary SSH; it never enables or relocates ordinary sshd.";
      }
      {
        assertion = lib.all (name:
          builtins.hasAttr name cfg.principals
          && absolute controllerStateHomes.${name}
          && lib.all (group: config.users.groups.${group}.gid != null && config.users.groups.${group}.gid > 0)
          (memberGroups name)) (lib.attrNames controllerStateHomes);
        message = "CI observers require installed principals, explicit primary GIDs and absolute XDG state bases.";
      }
      {
        assertion = lib.all (name:
          builtins.hasAttr name controllerStateHomes
          && builtins.length captureRoots.${name} <= 16
          && lib.all (root:
            absolute root
            && root != "/"
            && root != config.users.users.${name}.home
            && !(lib.hasPrefix "${root}/" authority)
            && !(lib.hasPrefix "${root}/" sources)
            && !(lib.hasPrefix "${authority}/" root)
            && !(lib.hasPrefix "${sources}/" root)
            && root != authority
            && root != sources)
          captureRoots.${name}) (lib.attrNames captureRoots);
        message = "Capture roots must be explicit read-only subtrees, not entire homes or owned authorities.";
      }
      {
        assertion = lib.all (uid: uid != null && uid > 0) controlBase.workload_uids;
        message = "Agent-managed workloads need explicit nonroot UIDs.";
      }
      {
        assertion = builtins.length (lib.unique controlBase.workload_uids) == builtins.length controlBase.workload_uids;
        message = "Source, native executor and build users must have distinct kernel UIDs.";
      }
      {
        assertion =
          lib.all (name: name == readerUser || config.users.users.${name}.uid != cfg.readerUid)
          (lib.attrNames config.users.users);
        message = "The native executor UID cannot alias another declared account.";
      }
      {
        assertion = lib.all (name:
          builtins.elem name config.services.openssh.settings.DenyUsers
          && toString config.users.users.${name}.shell == "${pkgs.shadow}/bin/nologin")
        [sourceUser readerUser];
        message = "Source/native executor roles cannot be login identities.";
      }
    ];

    # Use the existing system Nix; this executor never selects a native fork.
    nix = {
      gc.automatic = lib.mkForce false;
      optimise.automatic = lib.mkForce false;
      settings = {
        # Upstream root default; bind the effective group explicitly.
        build-users-group = lib.mkDefault "nixbld";
        max-jobs = cfg.maxJobs;
        cores = cfg.maxCores;
        min-free = 0;
        experimental-features = ["nix-command" "flakes"];
      };
    };
    environment.systemPackages = [agentPackage manager.package];
    environment.etc = {
      "abird-owned-build/role.json".source = pkgs.writeText "abird-owned-role.json" (builtins.toJSON role);
      "abird-owned-build/daemon.json".source = pkgs.writeText "abird-owned-daemon.json" (builtins.toJSON native);
      "abird-owned-build/control.json".source = pkgs.writeText "abird-owned-control.json" (builtins.toJSON control);
    };
    users.groups = {
      ${readerGroup}.gid = cfg.readerGid;
      abird-owned-control.gid = cfg.controlGid;
    };
    users.users =
      lib.genAttrs [sourceUser readerUser] (name: {
        isSystemUser = true;
        uid =
          if name == sourceUser
          then cfg.sourceUid
          else cfg.readerUid;
        group = readerGroup;
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow + "/bin/nologin";
      })
      // lib.genAttrs (lib.attrNames cfg.inputPrincipals) (_: {
        extraGroups = ["abird-owned-control"];
        # No startup rc/interpreter authority. '*' disables password matching
        # without making OpenSSH's non-PAM public-key account appear locked.
        shell = agent;
        hashedPassword = lib.mkDefault "*";
      });
    services.openssh.settings.DenyUsers = lib.mkAfter ([sourceUser readerUser] ++ lib.attrNames cfg.inputPrincipals);
    networking.firewall.allowedTCPPorts = lib.optional (cfg.inputPrincipals != {}) cfg.inputPort;
    services.abird-host-agent.buildExecutor.control = {
      enable = true;
      declarationFile = controlPath;
      xdgStateHome = cfg.xdgStateHome;
      users = lib.attrNames cfg.principals;
      slice = "abird-control.slice";
      maxConnections = cfg.maxConnections;
      connectionLifetimeSeconds = cfg.connectionLifetimeSeconds;
    };

    systemd = {
      # Ancestors/data authority only. Never create the journal root or launch gate.
      tmpfiles.rules = [
        "d ${cfg.xdgStateHome}/abird 0755 root root -"
        "d ${stateParent} 0700 root root -"
        "d ${cfg.xdgDataHome} 0755 root root -"
        "d ${cfg.xdgDataHome}/abird 0755 root root -"
        "d ${cfg.xdgDataHome}/abird/abird-host-agent 0755 root root -"
        "d ${dataParent} 0755 root root -"
        "d ${sources} 0710 root ${readerGroup} -"
        "d /run/abird/owned-input 0750 root abird-owned-control -"
      ];
      slices = {
        abird.sliceConfig = {
          CPUAccounting = true;
          MemoryAccounting = true;
          TasksAccounting = true;
          CPUQuota = "${toString (workPercent + cfg.controlReserve.cpu_percent)}%";
          CPUQuotaPeriodSec = "${toString cfg.resources.cpu_period_micros}us";
          MemoryMax = cfg.resources.memory_max + cfg.controlReserve.memory_max;
          MemorySwapMax = cfg.resources.swap_max;
          TasksMax = cfg.resources.tasks_max + cfg.controlReserve.tasks_max;
        };
        abird-build = {
          wantedBy = ["multi-user.target"];
          sliceConfig = {
            CPUAccounting = true;
            CPUQuota = "${toString workPercent}%";
            CPUQuotaPeriodSec = "${toString cfg.resources.cpu_period_micros}us";
            MemoryAccounting = true;
            MemoryHigh = cfg.resources.memory_high;
            MemoryMax = cfg.resources.memory_max;
            MemorySwapMax = cfg.resources.swap_max;
            TasksAccounting = true;
            TasksMax = cfg.resources.tasks_max;
          };
        };
        # No extra capacity. Native hard-stop addresses only this child; the
        # parent budget also accounts for the independently enabled publisher.
        abird-build-owned.sliceConfig = {
          CPUAccounting = true;
          MemoryAccounting = true;
          TasksAccounting = true;
        };
        abird-build-consumer = lib.mkIf consumer {
          sliceConfig = {
            CPUAccounting = true;
            MemoryAccounting = true;
            TasksAccounting = true;
          };
        };
        abird-control.sliceConfig = {
          CPUAccounting = true;
          CPUQuota = "${toString cfg.controlReserve.cpu_percent}%";
          CPUQuotaPeriodSec = "100ms";
          CPUWeight = 1000;
          MemoryAccounting = true;
          MemoryMax = cfg.controlReserve.memory_max;
          MemorySwapMax = 0;
          TasksAccounting = true;
          TasksMax = cfg.controlReserve.tasks_max;
        };
      };
      services = {
        "abird-owned-consumer@" = lib.mkIf consumer {
          description = "Fixed shared-store verification and root publication";
          serviceConfig = {
            ExecStart = "${manager.package}/libexec/abird-host-manager _owned-shared-acquire";
            User = "root";
            Group = "root";
            Slice = "abird-build-consumer.slice";
            StandardInput = "socket";
            StandardOutput = "journal";
            StandardError = "journal";
            Restart = "no";
            KillMode = "control-group";
            RuntimeMaxSec = cfg.deadlines.retention_seconds;
            TimeoutStopSec = "1s";
            LimitCORE = 0;
            UMask = "0077";
            NoNewPrivileges = true;
            UnsetEnvironment = ["NIX_REMOTE" "NIX_STORE" "NIX_STORE_DIR" "NIX_STATE_DIR" "NIX_CONFIG" "NIX_CONF_DIR" "NIX_USER_CONF_FILES" "LD_PRELOAD" "LD_LIBRARY_PATH" "LD_AUDIT"];
          };
        };
        harmonia = lib.mkIf publisher {
          serviceConfig.Slice = lib.mkForce "abird-build.slice";
        };
        nix-gc.enable = lib.mkForce false;
        nix-optimise.enable = lib.mkForce false;
        abird-owned-maintenance-request = {
          description = "Admit genuine GC through the owned queue";
          environment = environment;
          unitConfig.ConditionPathExists = "${authority}/bootstrap.complete";
          serviceConfig =
            controlService
            // {
              Type = "oneshot";
              ExecStart = "${agent} _owned-request-gc --role ${rolePath}";
              TimeoutStartSec = "10s";
              TimeoutStopSec = "2s";
            };
        };
        abird-owned-build-bootstrap = {
          description = "Explicit build executor provisioning; never automatic initialization";
          environment = environment;
          requires = ["abird-build.slice"];
          after = ["abird-build.slice" "systemd-tmpfiles-setup.service"];
          unitConfig.OnSuccess = ["abird-owned-build-supervisor.service"];
          serviceConfig =
            controlService
            // {
              Type = "oneshot";
              ExecStart = "${agent} _owned-bootstrap --role ${rolePath}";
              TimeoutStartSec = "30s";
              TimeoutStopSec = "2s";
            };
        };
        abird-owned-build-supervisor = {
          description = "Single durable owned execution controller";
          wantedBy = ["multi-user.target"];
          requires = ["abird-build.slice"];
          after = ["abird-build.slice" "systemd-tmpfiles-setup.service"];
          environment = environment;
          unitConfig.ConditionPathExists = "${authority}/bootstrap.complete";
          serviceConfig =
            controlService
            // {
              Type = "simple";
              ExecStart = "${agent} _owned-supervisor --role ${rolePath}";
              TimeoutStopSec = "2s";
            };
        };
        "abird-owned-fleet@" = {
          description = "One-shot foreground-capability CI observer %i";
          environment = environment;
          restartIfChanged = false;
          stopIfChanged = false;
          unitConfig.ConditionPathExists = "${authority}/bootstrap.complete";
          # Default root preserves credential-drop authority under systemd's
          # seccomp setup; explicit User=root can drop CAP_SETUID. No ambient caps.
          serviceConfig =
            builtins.removeAttrs controlService ["User"]
            // {
              Type = "simple";
              ExecStart = "${agent} _owned-controller --role ${rolePath} --attempt %i";
              RemainAfterExit = true;
              KillMode = "control-group";
              Delegate = true;
              ProtectHome = "read-only";
              ReadWritePaths =
                [
                  stateParent
                  "/sys/fs/cgroup/abird.slice/abird-control.slice/abird-owned-fleet@%i.service"
                ]
                ++ lib.mapAttrsToList (_: base: "${base}/abird/abird-host-manager/fleet-owned") controllerStateHomes;
              RuntimeMaxSec = "${toString cfg.deadlines.runtime_seconds}s";
              TimeoutStopSec = "2s";
            };
        };
        "abird-build-client@" = {
          description = "One immutable admitted owned attempt %i";
          environment = environment;
          after = ["nix-daemon.socket"];
          serviceConfig = {
            Type = "simple";
            # System-service root default; see the controller's seccomp note.
            Group = "root";
            Slice = "abird-build-owned.slice";
            ExecStart = "${agent} _owned-worker --role ${rolePath} --attempt %i";
            Restart = "no";
            RemainAfterExit = true;
            KillMode = "process";
            TimeoutStopSec = "${toString cfg.deadlines.stop_grace_seconds}s";
            Delegate = true;
            UMask = "0077";
            LimitCORE = 0;
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateMounts = true;
            ProtectSystem = "strict";
            ProtectHome = "tmpfs";
            BindReadOnlyPaths = lib.concatLists (lib.mapAttrsToList (name: stateHome:
              [
                "-${stateHome}/abird/abird-host-manager/fleet-owned"
                "-${config.users.users.${name}.home}/.gitconfig"
                "-${config.users.users.${name}.home}/.config/git"
              ]
              ++ (captureRoots.${name} or []))
            controllerStateHomes);
            BindPaths = ["/nix/store" "/nix/var/nix"];
            ReadWritePaths = [authority sources "/run/abird/owned-input" "/sys/fs/cgroup/abird.slice/abird-build.slice/abird-build-owned.slice"];
            RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK"];
            StandardOutput = "null";
            StandardError = "null";
          };
        };
        nix-daemon = {
          environment = environment;
          restartIfChanged = false;
          stopIfChanged = false;
          serviceConfig = {
            Type = lib.mkForce "simple";
            ExecStart = lib.mkForce ["" "${agent} _owned-daemon --policy ${daemonPath} --control ${controlPath}"];
            Slice = "abird-build-owned.slice";
            Restart = lib.mkForce "no";
            KillMode = lib.mkForce "process";
            Delegate = lib.mkForce true;
            LimitCORE = 0;
            UMask = "0077";
            PrivateMounts = true;
            BindPaths = ["/nix/store" "/nix/var/nix"];
            StandardOutput = "null";
            StandardError = "null";
          };
        };
      };
      sockets.abird-owned-consumer = lib.mkIf consumer {
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = "/run/abird/abird-host-agent/owned-build/consumer.sock";
          Accept = true;
          SocketUser = "root";
          SocketGroup = "abird-owned-control";
          SocketMode = "0660";
          MaxConnections = cfg.control.maxConnections;
          MaxConnectionsPerSource = 1;
          Backlog = cfg.control.maxConnections;
          RemoveOnStop = true;
        };
      };
      timers.abird-owned-maintenance-request = lib.mkIf (cfg.gcSchedule != null) {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.gcSchedule;
          Persistent = false;
        };
      };
      sockets.nix-daemon = {
        wantedBy = lib.mkForce [];
        socketConfig = {
          SocketMode = "0600";
          SocketUser = readerUser;
          SocketGroup = readerGroup;
          RemoveOnStop = true;
        };
      };
    };
  };
}
