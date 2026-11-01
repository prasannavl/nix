{pkgs}: let
  lib = pkgs.lib;
  root = "/tmp/agent-generation-boundary-test";
  agent = pkgs.writeShellScriptBin "abird-host-agent" ''
    export ABIRD_HOST_AGENT_STATE_DIR=${root}/state
    exec ${pkgs.abird-host-agent}/bin/abird-host-agent "$@"
  '';
  toolArgs = {
    inherit pkgs agent;
    hasDeclaredState = false;
    host = "fixture";
    stateDirectory = "${root}/state";
    systemStateDirectory = "${root}/default-state";
    backupRoot = "${root}/backups";
    runtimeDirectory = "${root}/runtime";
    configurationDirectory = "${root}/live-config";
  };
  tools = import ../services/abird-host-agent/admission-tools.nix toolArgs;
  inaccessibleTools = import ../services/abird-host-agent/admission-tools.nix (toolArgs // {stateDirectory = "${root}/inaccessible/state";});
  declaredTools = import ../services/abird-host-agent/admission-tools.nix (toolArgs // {hasDeclaredState = true;});
  registry = pkgs.writeText "generation-boundary-registry.json" (builtins.toJSON {
    schema_version = 1;
    domains = [
      {
        name = "serviceMoves";
        schema_version = 1;
        adapter = "stateful-service-placement";
        program = lib.getExe tools.statefulServicePlacement;
        authority_paths = ["service-placement-contract.json" "desired-resource-states.json" "resources.json"];
      }
    ];
  });
  placement = pkgs.writeText "generation-boundary-placement.json" (builtins.toJSON {
    schema_version = 3;
    predecessors = {
      "1".scope_aliases = {};
      "2".scope_aliases = {};
    };
    placements.fixture.database = {
      migration_kind = "stateful";
      role = "data";
    };
    moves = {};
  });
  resources = pkgs.writeText "generation-boundary-resources.json" (builtins.toJSON {
    schema_version = 1;
    resources = [];
  });
  desired = pkgs.writeText "generation-boundary-desired.json" (builtins.toJSON {
    schema_version = 1;
    resources = [];
  });
in
  assert lib.all (stateDirectory:
    !(builtins.tryEval (import ../services/abird-host-agent/admission-tools.nix (toolArgs // {stateDirectory = stateDirectory;}))).success)
  ["/" "relative" "/state/../outside" "/state//bad" "/state/.git" "/state\n"];
    pkgs.runCommand "abird-host-agent-generation-test" {
      nativeBuildInputs = [pkgs.jq pkgs.coreutils pkgs.findutils];
      PREFLIGHT = lib.getExe tools.generation;
    } ''
      mkdir ${root}
      cd ${root}
      mkdir -p legacy/etc legacy/sw/bin modern/etc/abird-host-agent
      printf 'pre-agent OS\n' >legacy/etc/nixos-version
      ln -s ${pkgs.runtimeShell} legacy/sw/bin/sh
      cp ${registry} modern/etc/abird-host-agent/generation-admission-registry.json
      cp ${placement} modern/etc/abird-host-agent/service-placement-contract.json
      cp ${resources} modern/etc/abird-host-agent/resources.json
      cp ${desired} modern/etc/abird-host-agent/desired-resource-states.json
      chmod u+w modern/etc/abird-host-agent/*.json

      admit() {
        ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/$1" "$PREFLIGHT" --json "$PWD/$2" "$3" "$4"
      }
      reject() {
        local expected="$1" status
        shift
        if admit "$@" >rejected.out 2>rejected.err; then
          echo "unexpected admission: $*" >&2
          exit 1
        else
          status=$?
        fi
        test "$status" -lt 124
        grep -F -- "$expected" rejected.err
      }

      # Real dispatcher, adapter and agent. A nonempty predecessor is not a new OS.
      for action in switch test dry-activate; do
        admit legacy modern "$action" normal | jq -e '
          .result.mode == "normal" and .result.deferred_resources.count == 0
          and all(.result.domains[0].authority[];
            .current_sha256 == null and (.incoming_sha256 | test("^[0-9a-f]{64}$")))'
        admit modern legacy "$action" rollback | jq -e '
          .result.mode == "rollback" and .result.domains[0].transition == "removed"
          and all(.result.domains[0].authority[];
            .incoming_sha256 == null and (.current_sha256 | test("^[0-9a-f]{64}$")))'
      done
      test ! -e state
      test ! -e default-state
      test ! -e runtime
      test ! -e live-config
      reject 'missing the projection admission registry' modern legacy switch normal
      reject 'boot activation cannot guarantee projection admission' legacy modern boot normal
      reject 'boot activation cannot guarantee agent-free admission' modern legacy boot rollback

      # Actual empty hold reconciliation creates only scaffolding + its mutex.
      ${agent}/bin/abird-host-agent --resource-manifest modern/etc/abird-host-agent/resources.json \
        _reconcile hold apply
      test -f state/state.lock
      test ! -s state/state.lock
      admit legacy modern switch normal >/dev/null
      admit modern legacy switch rollback >/dev/null

      # Directory, helper and unit evidence forbids pretending an agent was absent.
      for evidence in etc/abird-host-agent etc/abird-host-agent.json \
        sw/bin/abird-host-agent sw/bin/.abird-host-agent-wrapped \
        sw/bin/abird-host-agent-generation-preflight \
        sw/bin/abird-host-agent-projection-preflight \
        etc/systemd/system/abird-host-agent-holds.service; do
        for shape in file directory dangling; do
          cp -a legacy broken
          mkdir -p "broken/$(dirname "$evidence")"
          case "$shape" in
            file) touch "broken/$evidence" ;;
            directory) mkdir "broken/$evidence" ;;
            dangling) ln -s /missing-agent-evidence "broken/$evidence" ;;
          esac
          reject 'missing current authority' broken modern switch normal
          reject 'missing incoming authority' modern broken switch rollback
          rm -r broken
        done
      done

      # Partial documents and registered empty/corrupt authority retain the old rules.
      for document in resources.json desired-resource-states.json service-placement-contract.json; do
        cp -a legacy partial
        mkdir -p partial/etc/abird-host-agent
        cp "modern/etc/abird-host-agent/$document" "partial/etc/abird-host-agent/$document"
        reject 'missing current authority' partial modern switch normal
        reject 'missing incoming authority' modern partial switch rollback
        rm -r partial
      done
      cp -a modern broken
      rm broken/etc/abird-host-agent/service-placement-contract.json
      reject 'missing current authority' broken modern switch normal
      rm -r broken
      for shape in directory dangling fifo; do
        cp -a modern broken
        rm broken/etc/abird-host-agent/generation-admission-registry.json
        case "$shape" in
          directory) mkdir broken/etc/abird-host-agent/generation-admission-registry.json ;;
          dangling) ln -s /missing-registry broken/etc/abird-host-agent/generation-admission-registry.json ;;
          fifo) mkfifo broken/etc/abird-host-agent/generation-admission-registry.json ;;
        esac
        reject 'invalid projection admission registry file' broken modern switch normal
        reject 'invalid projection admission registry file' modern broken switch rollback
        rm -r broken
      done
      ln -s /missing-current broken
      reject 'current generation is unavailable' broken modern switch normal
      rm broken
      touch broken
      reject 'current generation is unavailable' broken modern switch normal
      rm broken
      reject 'missing incoming authority' modern nonexistent switch rollback

      # Every retained artifact, including unknown future state, blocks both edges.
      for evidence in state/holds/hold.json state/desired-resource-state-receipts/receipt.json \
        state/desired-resource-state-deferrals/deferral.json state/activation-authorizations/token \
        state/declaration-releases/release.json state/jobs/job.json state/.future-state \
        default-state/holds/hold.json backups/snapshot runtime/broker/token; do
        mkdir -p "$(dirname "$evidence")"
        printf 'retained; deliberately not parsed\n' >"$evidence"
        reject 'retained host-agent state' legacy modern switch normal
        reject 'retained host-agent state' modern legacy switch rollback
        rm "$evidence"
      done
      for shape in file dangling fifo; do
        case "$shape" in
          file) touch state/unknown ;;
          dangling) ln -s /missing-state state/unknown ;;
          fifo) mkfifo state/unknown ;;
        esac
        reject 'retained host-agent state' legacy modern switch normal
        reject 'retained host-agent state' modern legacy switch rollback
        rm state/unknown
      done
      printf 'not a mutex\n' >state/state.lock
      reject 'retained host-agent state' legacy modern switch normal
      reject 'retained host-agent state' modern legacy switch rollback
      : >state/state.lock
      ln state/state.lock aliased-lock
      reject 'retained host-agent state' legacy modern switch normal
      rm aliased-lock
      mv state real-state
      ln -s real-state state
      reject 'retained host-agent state' legacy modern switch normal
      reject 'retained host-agent state' modern legacy switch rollback
      rm state
      mv real-state state

      # An inaccessible ancestor is not an absent state directory (sandbox uid).
      test "$(id -u)" != 0
      mkdir inaccessible
      chmod 000 inaccessible
      saved_preflight="$PREFLIGHT"
      PREFLIGHT=${lib.getExe inaccessibleTools.generation}
      reject 'inspect host-agent directory' legacy modern switch normal
      reject 'inspect host-agent directory' modern legacy switch rollback
      chmod 700 inaccessible
      rmdir inaccessible
      ln -s /missing-state-parent inaccessible
      reject 'inspect host-agent directory' legacy modern switch normal
      reject 'inspect host-agent directory' modern legacy switch rollback
      rm inaccessible
      PREFLIGHT="$saved_preflight"

      mkdir -p live-config
      ln -s /missing-live-manifest live-config/resources.json
      reject 'retained host-agent state' legacy modern switch normal
      rm live-config/resources.json

      # The reverse proof runs BEFORE first installation, not just during rollback.
      for kind in desired moves declarations; do
        cp -a modern active
        case "$kind" in
          desired)
            jq '.resources = [{id: "service:database"}]' ${desired} \
              >active/etc/abird-host-agent/desired-resource-states.json
            reason='empty desired resource authority'
            ;;
          moves)
            jq '.moves.example = {}' ${placement} >active/etc/abird-host-agent/service-placement-contract.json
            reason='pre-agent rollback refuses service moves'
            ;;
          declarations)
            mkdir active/etc/abird-host-agent/declared-holds
            touch active/etc/abird-host-agent/declared-holds/hold
            reason='pre-agent rollback refuses declared holds'
            ;;
        esac
        reject "$reason" legacy active switch normal
        grep -F 'rejected rollback to its unregistered predecessor' rejected.err
        reject "$reason" active legacy switch rollback
        rm -r active
      done

      cp -a modern invalid-resources
      jq '.schema_version = 999' ${resources} >invalid-resources/etc/abird-host-agent/resources.json
      reject 'unsupported resource manifest schema version' legacy invalid-resources switch normal
      grep -F 'rejected rollback to its unregistered predecessor' rejected.err
      reject 'unsupported resource manifest schema version' invalid-resources legacy switch rollback

      # Nix declaration facts protect enrollment even without any domain adapters.
      cp -a modern no-domains
      jq '.domains = []' ${registry} >no-domains/etc/abird-host-agent/generation-admission-registry.json
      saved_preflight="$PREFLIGHT"
      PREFLIGHT=${lib.getExe declaredTools.generation}
      reject 'agent-free transition refuses declared holds or desired resource states' legacy no-domains switch normal
      reject 'agent-free transition refuses declared holds or desired resource states' no-domains legacy switch rollback
      PREFLIGHT="$saved_preflight"
      reject 'boot activation cannot guarantee agent-free admission' legacy no-domains boot normal
      reject 'boot activation cannot guarantee agent-free admission' no-domains legacy boot rollback
      admit legacy no-domains switch normal >/dev/null
      admit no-domains legacy switch rollback >/dev/null

      # Registered domains still cannot disappear via a normal empty-registry target.
      cp -a modern removed
      jq '.domains = []' ${registry} >removed/etc/abird-host-agent/generation-admission-registry.json
      reject 'durable lifecycle tombstones' modern removed switch normal
      admit modern modern switch normal >/dev/null
      admit legacy modern switch normal >/dev/null
      admit modern legacy switch rollback >/dev/null

      mkdir "$out"
      printf '%s\n' 'Pre-agent install/rollback and retained-authority regressions passed.' >"$out/result"
    ''
