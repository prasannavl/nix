{
  config,
  lib,
  pkgs,
  ...
}: let
  required = type: description: lib.mkOption {inherit type description;};
  positive = lib.types.ints.positive;
  unsigned = lib.types.ints.unsigned;
  fields = names: type: description:
    lib.genAttrs names (_: required type description);
  resources = lib.types.submodule {
    options =
      (fields ["cpu_quota_micros" "cpu_period_micros" "memory_high" "memory_max" "tasks_max" "min_store_free_bytes" "min_state_free_bytes"] positive "Explicit approved work limit/headroom; not a reservation certificate.")
      // {swap_max = required unsigned "Approved aggregate swap ceiling in bytes.";};
  };
  deadlines = lib.types.submodule {
    options = fields ["heartbeat_seconds" "stale_seconds" "owner_seconds" "queue_seconds" "runtime_seconds" "stop_grace_seconds" "stop_limit_seconds" "retention_seconds"] positive "Immutable owned lifecycle deadline in seconds.";
  };
  reserve = lib.types.submodule {
    options = fields ["memory_max" "tasks_max" "cpu_percent"] positive "Explicit independent control-service budget.";
  };
in {
  enable = lib.mkEnableOption "the durable shared-native-store build executor (separate rollout approval required)";
  acceptSubmissions = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Explicit post-qualification admission gate; does not initialize or recover authority.";
  };
  gitPackage = lib.mkOption {
    type = lib.types.package;
    default = pkgs.git;
    description = "Immutable source Git executable.";
  };
  runtimePackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = "Explicit offline helper dependencies beyond fixed manager/Git/Nix/shell/coreutils runtimes. The configured /bin/sh backing package is included, but ambient system PATH packages are not. Undeclared helper dependencies fail closed under the unchanged bounded exact-inode read scope.";
  };
  gitConfiguration = required lib.types.path "Immutable full Git context; includes explicit transport/credential policy and sealed-repository safe.directory rules. No private key contents in the store.";
  repositories = required (lib.types.attrsOf lib.types.str) "Approved repository identity to native https/ssh/file URL mapping.";
  identity = required (lib.types.submodule {options = fields ["authority_id" "builder_id" "store_id"] lib.types.str "Stable owned authority identity.";}) "Stable storage/authority labels; bootstrap additionally pins physical native objects.";
  principals = required (lib.types.attrsOf (lib.types.submodule ({name, ...}: {
    options = {
      uid = lib.mkOption {
        type = positive;
        default = config.users.users.${name}.uid;
        defaultText = lib.literalExpression "the declared account UID";
        description = "Existing caller UID, not a workload UID; checked against the account.";
      };
      issuer = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Stable authenticated issuer; defaults to the declared control-account name.";
      };
    };
  }))) "Explicitly admitted existing SSH accounts. No key or sudo authority added.";
  inputPrincipals = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        uid = lib.mkOption {
          type = positive;
          default = config.users.users.${name}.uid;
          defaultText = lib.literalExpression "the declared account UID";
          description = "Existing input-only SSH account UID, distinct from control and workload UIDs.";
        };
        issuer = required lib.types.str "Ordinary issuer whose admitted remote captures this account may deliver.";
      };
    }));
    default = {};
    description = "Dedicated authenticated source relays. Existing accounts/authorized keys get a fixed agent login shell, password-disabled account and admitted input-only endpoint; ordinary SSH/control/submission are denied.";
  };
  inputPort = lib.mkOption {
    type = lib.types.ints.between 1 65535;
    default = 2022;
    description = "Dedicated admitted input SSH port; listener/crypto/relay live in the original worker, never ordinary sshd.";
  };
  gcSchedule = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Optional systemd calendar for genuine queued GC intent; no legacy profile cleanup or collector outside admission.";
  };
  sourceUid = required positive "Dedicated source UID; never a native store client.";
  readerUid = required positive "Dedicated unprivileged native-client UID.";
  readerGid = required positive "Private source traversal/native socket group.";
  controlGid = required positive "Independent control/data-delivery group.";
  resources = required resources "Approved aggregate limits; no capacity defaults.";
  controlReserve = required reserve "Independent supervisor/bootstrap/control budgets, outside the work slice.";
  sourceLimits = required (lib.types.submodule {options = fields ["entries" "bytes" "depth"] positive "Bounded source copy/observation limit; no physical quota claim.";}) "Private source limits.";
  deadlines = required deadlines "Immutable request deadlines.";
  maxJobs = required positive "Native job ceiling.";
  maxCores = required positive "Native per-job core ceiling.";
  submissionAgeSeconds = required positive "Maximum new submission age.";
  futureSkewSeconds = required unsigned "Allowed future submission clock skew.";
  replaySeconds = required positive "Replay/tombstone horizon.";
  controlTimeoutMillis = required positive "Bounded control transaction timeout.";
  maxConnections = required (lib.types.ints.between 1 64) "Concurrent control reserve bound.";
  connectionLifetimeSeconds = required (lib.types.ints.between 1 60) "Control service hard lifetime.";
  xdgStateHome = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib";
    description = "Absolute XDG state base; authority itself is explicit-bootstrap only.";
  };
  xdgDataHome = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/abird-data";
    description = "Absolute separate XDG data base; readers cannot traverse private journal authority.";
  };
}
