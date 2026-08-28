# abird-host-manager

`abird-host-manager` is a standalone Rust control plane for host inventory,
native SSH, service operations, durable host-agent jobs, and crash-resumable
service, whole-host, or instance moves. The former Bash host manager, Python
data migrator, and transient migration manager are retired; there is no legacy
provider or fallback path.

The manager owns ordering and a durable transaction journal. Repository-backed
fleet workflows keep that journal on the configured controller from the first
command; normal operator commands transparently dispatch there, and deployment
reconciliation uses the same state. `--controller local` selects local
execution, while `--controller HOST --state-dir RUN` selects an isolated state
directory beneath the remote controller's manager state root. A bare
`--state-dir` retains standalone-local compatibility. Every mutation is accepted
and persisted by the selected host agent before it runs. The manager then polls
the immutable job ID. Reconnecting after an SSH failure submits or queries the
same specification; it cannot create a second mutation.

For an ad hoc repository-local run, `--local-run NAME` is shorthand for local
execution with state at `.agents/runs/NAME/host-manager`. It is intentionally
incompatible with both `--controller` and `--state-dir`; run names are bounded,
path-safe identifiers and temporary run contents are ignored by Git.

Global `--local` is the complete no-push lifecycle mode. It always uses the
invoking repository checkout, its current branch, and the journal at
`.agents/runs/local/host-manager`; it never dispatches to a controller, creates
a controller-owned publication checkout, performs a push preflight, pushes, or
verifies a remote ref. Projection and closeout commits are created directly in
the clean invoking checkout. Any Nixbot workflow step runs synchronously from
that checkout at its exact committed `HEAD`, with logs attached to the local
terminal and outcomes retained only in the local manager journal. Local phase
commits also retain an explicit controller-reconcile exclusion, so deploying a
local commit cannot cause the controller to adopt the invoking journal.

The controller repository mirror is intentionally read-only. Its dedicated
Nixbot identity performs fetches and boot/deploy-time mirror refreshes, but can
never publish. An explicit operator-dispatched phase command temporarily
forwards the operator's existing SSH agent; after validation and commit, the
controller uses that agent only for the fast-forward projection push. It stores
no write-capable repository key. If no agent is available, no loaded key may
write the repository, or the push is rejected, the command fails before any
runtime handoff.

## Migration commands and states

```text
source_active --move--> moved --prepare--> prepared --run--> target_active
                                      ^                 |
                                      |---- prepare ----|

prepared or target_active --close--> closing_complete|closing_rollback
                                      --deployed closeout--> closed
```

- `move` validates source placement, agent, resource, data paths and readiness;
  validates the declared target or its provisioning route; publishes the seeded
  projection; holds the target; and performs a verified warm seed while source
  remains active.
- `prepare` holds both writers and creates a verified checkpoint. Before the
  first run it copies source to target. After target has run, it backs up target
  and synchronizes target back to source, preserving the newest authority.
- `run` publishes target-active placement, activates and verifies target, and
  applies and verifies routing while source remains held for recovery. The old
  name `cutover` remains a compatibility alias.
- `close` selects completion after a successful current run, otherwise rollback.
  `--complete`/`-c` and `--rollback`/`-r` persist an explicit direction without
  bypassing safety. `--complete --force` is break glass for an already-published
  target-active projection: it verifies exact holds, source inactivity, target
  readiness and routing, then records the missing run evidence. Rollback
  performs reverse synchronization when target may have written. Close first
  folds placement into `data/service-placements.nix` and retains the temporary
  move in an adoption phase with the exact terminal lease contract. After that
  revision deploys successfully, it commits and deploys a clean stable revision
  with the move removed. Only successful cleanup deployment may release the
  inactive-side hold and archive the journal. In normal mode both revisions use
  exact revision-bound durable controller Nixbot jobs. In `--local` mode they
  deploy from the invoking checkout without a push or controller-owned journal.

Each command snapshots an ordered, versioned step plan in the transaction
journal. Completed steps are adopted, ambiguous jobs are reconciled by exact ID,
and explicitly repeating `run` automatically gives terminal failed jobs durable
successor attempt IDs. `transaction resume` is a generic recovery convenience;
commands reconcile their own incomplete executions.

Mutating commands execute by default. `--dry` (alias `--dry-run`) is strictly
read-only. The hidden `--execute` flag is accepted only for compatibility.

## Output

Human-readable output is the default. Interactive terminals update the active
step in place; redirected output and systemd journals receive the same events as
stable lines without terminal control sequences. Completed steps stay visible,
and the final summary reports the durable state and safe next command.

Every public command has an explicit output contract. Structured inspection,
collection, action, fleet, workflow, backup, and job commands use the same
visual grammar while retaining their own domain states. Read-only inspection
shows facts without a success glyph. Actions distinguish completed,
accepted/running, already-satisfied, failed, and dry-run outcomes; durable job
submission is never presented as completion until the retained job is terminally
successful. Repository lifecycle operations, direct service/unit/resource
actions, wipes, backups, and instance synchronization expose timed transient
steps without pretending those operations belong to the durable move transaction
state machine.

Seed, final-transfer, reverse-transfer, and backup copy steps show the transfer
stage, engine, percentage, copied and total bytes, average throughput, estimated
time remaining, entry counts, and agent detail whenever the retained job
provides those fields. Warm seed therefore remains observable while the source
continues serving traffic:

```text
Warm seed zulip-tearoff-20260826

✓ Validate endpoints, resources, routes, and job policy  0.8s
● Copy live source data to held target  Copying · rsync · 63% · 18 GiB / 29 GiB · 112 MiB/s · 1m 37s left · 84,201/132,440 entries
```

Use global `--json` for one stable machine-readable JSON document on stdout.
JSON mode suppresses human progress rendering; command and step status,
attempts, evidence, and failures remain in the final document. Controller
dispatch forwards the selected mode, while host-manager-to-agent calls continue
to use their private JSON protocol independently.

Logs are an intentional streaming contract: use their `--output text|json`
option for text or JSONL snapshots and follow streams. Interactive `host ssh`
and `host exec` are byte-transparent passthrough contracts. Global `--json` is
rejected for these streaming and passthrough commands rather than wrapping,
buffering, or corrupting their output.

## Nix-native service moves

New logical service moves commit one high-level declaration under
`data/service-moves/`. The stable role lives in `data/service-placements.nix`.
Nix evaluates those declarations with the service capsule's migration contract
and derives the exact placement, holds, activation identity, route, affected
hosts, and transition digest. Host-manager executes only that evaluated result;
JSON used at the Nix/Rust boundary is ephemeral transport and is never committed
configuration.

`move`, `prepare`, and `run` commit their requested Nix state and reconcile the
fine-grained resources directly, without a NixOS deployment. `close` uses two
deployments: an adoption revision which keeps the recovery lease, then a clean
stable revision which removes the temporary move. Stateful placement changes are
also guarded at the NixOS pre-switch boundary: a candidate role change must
carry exactly one matching adoption transition, and the existing desired-state
preflight must prove the corresponding runtime hold and activation evidence.
Deploying controller-authoritative nonterminal Nix intent can initialize its
runtime journal and invoke the same reconciler. Terminal adoption without an
existing evidence-bearing journal is rejected.

## Legacy phase projections

Existing resource projections and historical JSON-backed transactions retain a
compatibility path under `data/phase-projections/`. New logical service moves do
not write JSON phase projections. The compatibility adapter remains digest
strict and must not reinterpret an old transaction as a Nix-native move.

Pvl keeps the placement and move inputs disabled by default because it has no
service migration capsule or multi-role placement topology. The shared
evaluator, admission check, and manager implementation are present, but
authoring a move requires Pvl-owned schema-2 placement state, a move directory,
and an eligible service migration contract.

Publication and deployment reconciliation have deliberately different Git
capabilities. Operator phase decisions may publish through their ephemeral
forwarded SSH agent. Deployment reconciliation only consumes a projection that
is already present in the read-only controller mirror; it never commits or
pushes and needs no forwarded agent or write Git access. In both runtime and
`--skip-runtime` modes, successful publication is required before the command
may continue. `--skip-runtime` stops immediately after that durable publication.

For every remotely dispatched non-dry `move`, `prepare`, `run`, rollback, and
`close`, the dispatcher forwards a valid local SSH agent when one is available.
Before the lifecycle journal is mutated, the controller refreshes its owned
publication checkout and runs `git push --dry-run` against the exact branch with
the exact configured publication transport. This catches authentication,
transport, and obvious ref-update failures without changing the remote; the real
push remains authoritative for server-side hooks and branch policy. A specific
credential mechanism is not the gate. Read-only inspection, `--dry`, and
`transaction resume` run no write preflight.

The normal move has four commands:

```console
abird-host-manager service move zulip \
  --from abird-gondor-corp --to abird-gondor-zulip \
  --id zulip-tearoff-20260820
abird-host-manager transaction prepare zulip-tearoff-20260820
abird-host-manager transaction run zulip-tearoff-20260820
abird-host-manager transaction close zulip-tearoff-20260820
```

To keep the entire lifecycle in the invoking checkout with local commits and no
push, add global `--local` to every invocation:

```console
abird-host-manager --local service move zulip \
  --from abird-gondor-corp --to abird-gondor-zulip \
  --id zulip-tearoff-20260820
abird-host-manager --local transaction prepare zulip-tearoff-20260820
abird-host-manager --local transaction run zulip-tearoff-20260820
abird-host-manager --local transaction close zulip-tearoff-20260820
```

The checkout must be on the configured projection branch and clean before each
commit-producing command. Each successful phase leaves a normal Git commit in
that checkout. Nixbot may read or best-effort fetch ordinary refs while
preparing its isolated execution tree, but host-manager performs no Git push and
does not require the commit to exist on a remote.

At any point after `move`, `prepare` and `run` may alternate. Use
`transaction close --rollback` to force rollback or `close --complete` to force
safe target completion with normal run evidence. Use `close --complete --force`
only as the recorded break-glass evidence override. `--skip-runtime` publishes
and validates declarative intent while leaving runtime reconciliation to
deployment; it cannot be combined with forced completion.

After close publishes and verifies its exact Git revision, an interactive
terminal asks whether to run the required Nixbot deployment. Enter or `y` keeps
the deployment managed and followed by host-manager; `m` leaves the deployment
step pending and prints the exact bounded `nix run .#nixbot -- deploy ...`
command for an operator handoff. `close --yes` selects managed deployment
without prompting, while `close --manual-deploy` selects the handoff directly.
Automation and `--json` default to managed deployment unless `--manual-deploy`
is explicit.

While host-manager follows a managed deployment, the one-line status includes
the latest retained Nixbot line. Press `l` to show or hide the durable live log
tail; `Ctrl-C` retains its normal signal behavior. The log tail belongs to the
host-agent job, so a reconnect can recover recent output rather than depending
on the original SSH stream.

Without `--local`, both managed and manual deployment consume an exact revision
that must already exist and be verified on the authoritative remote;
`--manual-deploy` changes who runs it, not publication. With `--local`, both
choices consume the exact local commit instead: Enter/`y` or `--yes` runs Nixbot
synchronously from this checkout, while `m` or `--manual-deploy` prints the
exact local command and leaves the local close step pending. For `prepare` and
`run`, `--skip-runtime` stops after the local commit in `--local` mode and after
verified publication in normal mode.

Standalone holds are minimal phase projections, not a separate runtime-only
mechanism:

```console
abird-host-manager resource hold set abird-gondor-zulip service:abird-zulip \
  --id zulip-maintenance-20260821
abird-host-manager resource hold clear abird-gondor-zulip service:abird-zulip \
  --id zulip-maintenance-20260821
```

Both commands publish desired state first. `--skip-runtime` defers the exact
same change to deployment. `clear` releases the matching epoch without starting
the service; normal declarative lifecycle or a later projected activation owns
any start. The same hold can therefore be added through the manager and removed
by deploy, or added by deploy and removed through the manager.

Deployment and immediate reconciliation submit the same deterministic host-agent
transaction and activation job. They may therefore be intermixed at every
boundary: a deployment adopts a job already completed by the controller, and the
controller adopts the identical job already completed during deploy. A reviewed
Nix deployment is authorized by repository provenance. Dynamic manager
activation must first retain the matching brokered receipt. Both remain bounded
by the exact projection, hold epoch, local resource allowlist, and unrelated
holds.

Run activates and verifies the target before applying the allowlisted route
profile. Manager-brokered rollback from an activated target holds the target,
reverse-copies and verifies data, persists a rollback receipt, and only then
activates the source and restores its route. Before deriving that compensation,
the manager adopts an exact deployment-first cutover job so a target start is
not lost. The inactive endpoint remains held after run or rollback. Projected
`transaction close` persists canonical placement and a deployed closeout
reconciler, so an older controller cannot release the final safety hold. The
exact closeout revision must then be deployed to the source, target, effect
hosts, and controller: their running generations otherwise still retain the old
projection and may reassert its holds or route. The final inactive hold is
released and the journal archived only after that deploy succeeds. After an
interruption, use `transaction resume ID`. Resume inspects the journal:
projected transactions reconcile to their already-published desired phase with
full activation-authority validation, while legacy transactions continue only
their exact pending action. It never chooses or publishes a new phase.

A publication authentication failure is safe to retry. Make a write-authorized
credential available to the configured publication transport and repeat the same
phase command; a forwarded local SSH agent is the normal controller setup, not a
protocol requirement. If an initial move remains planned with no published
projection, repeat the exact move and ID without `--force-existing`; that is the
normal setup/publication retry. Reserve `--force-existing` for an advanced or
ambiguous existing transaction that the operator has inspected and explicitly
chooses to attach to. The controller refreshes from the authoritative branch,
adopts an exact commit if the prior push actually landed, or recreates the same
deterministic projection if it did not. Runtime reconciliation cannot start
until that exact revision is confirmed published, so the retry neither creates a
second transaction nor replays a migration job.

The Nixbot package explicitly carries the hostname and address-discovery tools
used to classify a controller self-deployment. A self-target reuses the outer
host-local deployment lock instead of attempting to acquire it again inside its
transient activation unit. This keeps controller closeout deployment serialized
without allowing a nested lock to deadlock its own deploy.

The operator checkout may be behind the authoritative branch because the
controller publishes projection commits. It may not have unpublished commits or
divergent history; the dispatcher fails closed on either condition. The
controller's private checkout, not the operator checkout, remains the only
publication worktree.

## Native configuration

For ordinary inventory, SSH, logs, service, and fleet operations, the manager
can evaluate the repository's existing Nixbot inventory directly. When invoked
from the repository root or any directory below it, the manager discovers the
root and uses `hosts/nixbot.nix` automatically:

```console
abird-host-manager host list --group abird-gondor
```

`--config`/`ABIRD_HOST_MANAGER_CONFIG` always takes precedence. This keeps the
standalone interface explicit outside the repository and supports JSON policy
configurations. `--repo-root`/`ABIRD_HOST_MANAGER_REPO_ROOT` selects a specific
repository when discovery should not start at the current directory.

For a Nix inventory, the sibling `*.override.nix` file is applied automatically
with Nixbot's recursive attribute-set merge semantics. Override its location
with `ABIRD_HOST_MANAGER_CONFIG_OVERRIDE` or `NIXBOT_CONFIG_OVERRIDE_PATH`. Host
commands use the effective operator user/key, while host-agent, migration, and
backup traffic keeps the primary Nixbot user/key. Every proxy hop resolves its
own effective operator transport.

Plain identity paths are used directly. An identity ending in `.age` is
decrypted lazily into a private process-owned temporary directory, cached for
the process lifetime, and removed on exit. `AGE_KEY_FILE` selects the decrypt
identity; otherwise the manager checks the same user and Nixbot identity paths
as Nixbot. `ABIRD_HOST_MANAGER_AGE` overrides the external Age program path.
Configured known-hosts data remains strict. With no configured host keys, the
manager follows Nixbot's process-isolated trust model: `accept-new` writes only
to a private temporary known-hosts file and never reads or mutates the
operator's persistent SSH configuration or trust store.

It maps Nixbot targets, users, nested proxy hops, groups, resource IDs, and
deployment identities without a generated mirror file. Proxy hops are resolved
from inventory to concrete OpenSSH commands, with an explicit null OpenSSH
configuration and global trust store, so they do not depend on ambient aliases
or credentials. The repository config names controller and transfer-broker
capabilities independently; both currently resolve to `abird-ci`, but workflow
and deploy routes use only the controller while data movement uses only the
transfer broker. For moves, the adapter also derives the target's existing
parent as its provisioning endpoint, endpoint deployments for target setup, and
the stack's shared proxy role for cutover and rollback. An explicit JSON policy
is therefore optional and is reserved for standalone or unusual infrastructure
whose controller, routes, or polling policy cannot be inferred safely. The
repository inventory uses the following capability shape:

```nix
config = {
  controller = "controller";
  transferBroker = "broker";
  builders = ["builder"];
  registries.nix = {
    host = "builder";
    url = "https://cache.example.invalid";
  };
};
```

These values are canonical host resource IDs, not SSH aliases. The first builder
is Nixbot's default unless the operator passes `--build-host`. Registry entries
remain protocol-specific so a future `registries.podman` does not inherit Nix
cache semantics. A bounded compatibility reader accepts the former `ci.host` and
`buildCache` shape during rollout; new configuration must use this schema.

```json
{
  "schema_version": 1,
  "controller": "controller",
  "transfer_broker": "controller",
  "ssh": {
    "program": "/run/current-system/sw/bin/ssh",
    "args": ["-o", "StrictHostKeyChecking=yes"],
    "connect_timeout_seconds": 10,
    "agent_poll_interval_ms": 1000,
    "job_timeout_seconds": 86400
  },
  "hosts": {
    "source": {
      "address": "10.10.30.60",
      "user": "pvl",
      "proxy_jump": "bastion",
      "nixbot_deploy": { "host": "source-real" },
      "agent_prefix": ["/run/wrappers/bin/sudo", "-n"],
      "broker_ssh_args": []
    },
    "target": {
      "address": "10.10.30.62",
      "user": "pvl",
      "nixbot_deploy": { "host": "target-real" },
      "agent_prefix": ["/run/wrappers/bin/sudo", "-n"],
      "broker_ssh_args": []
    },
    "bastion": {
      "address": "bastion.example.test",
      "user": "pvl",
      "proxy_command": "cloudflared access ssh --hostname %h"
    },
    "controller": {
      "address": "local",
      "local": true
    }
  },
  "operation_routes": {
    "deploy-target-gated": {
      "executor": "controller",
      "resource": "controller:nixbot",
      "kind": "nixbot_deploy",
      "nixbot_deploy": { "endpoint": "target" }
    },
    "deploy-cutover": {
      "executor": "controller",
      "resource": "controller:nixbot",
      "kind": "nixbot_deploy",
      "nixbot_deploy": {
        "host": "proxy",
        "nix_config": "proxy-zulip-target"
      }
    },
    "deploy-rollback": {
      "executor": "controller",
      "resource": "controller:nixbot",
      "kind": "nixbot_deploy",
      "nixbot_deploy": { "endpoint": "source" }
    }
  }
}
```

Executors are inventory names, `$source`, or `$target`. Routed kinds are
`named`, `transfer`, `verify_transfer`, `file_state`, `ready`, `provision`, and
`deploy`, plus the typed `nixbot_deploy` controller capability. A routed phase
boundary may also name its `phase_projection` executor and resource; that owner
applies the allowlisted effect directly instead of initiating a deployment. A
Nixbot request keeps the real connection `host` separate from its optional
`nix_config`; the corresponding Nixbot CLI uses `--host`/`--hosts` and
`--nix-config`. For reusable move inventories, `{"endpoint":"source"}` and
`{"endpoint":"target"}` resolve the selected host's `nixbot_deploy` request;
literal requests remain available for fixed infrastructure or ingress routes.
Only declarative boundary actions are routed. Setup skips deployment when the
target agent is reachable and exposes matching named data roots; otherwise it
optionally provisions the target and deploys it held. Cutover and rollback
require their respective deployment routes. A controller host agent can
therefore continue an accepted Nixbot/repository deployment if the manager
disconnects.

Seed, final copy, reverse copy, verification, and backup are not profiles. The
manager resolves source and target data roots by stable name, requires identical
exact-subtree exclusions, and persists the immutable path mapping in its
transaction before the first copy. Legacy `data_paths` remain an identical-path
shorthand. The manager then submits the mapping and source/target endpoints to
the configured or repository-derived controller agent. Its durable broker job
delegates the existing Nixbot identity through a short-lived forwarded SSH
agent; this broker-scoped transfer credential is separate from the operator
agent lent to a phase command for Git publication. Rsync and tar payloads travel
directly source-to-target. No peer key, target-side credential, controller
staging tree, or additional listener is required. `broker_ssh_args` describes
reachability from within the managed network independently from the manager's
ordinary SSH path.

Each inventory host may set `host_resource` to the Nix-generated aggregate
resource ID for whole-host backups and moves. It defaults to
`host:<inventory-name>`. Source and target IDs may differ, so host renames do
not require aliasing their manifests. Hosts may also declare `groups`;
`host list --group NAME --hosts SELECTORS` supports exact names, `*`/`?` globs,
`all`, and ordered `-` exclusions while failing closed when a selector matches
nothing. Remote rsync inherits `agent_prefix` by default, so an ordinary
`nixbot` inventory entry with `agent_prefix = ["/run/wrappers/bin/sudo", "-n"]`
reads root-owned data while retaining numeric owners, ACLs, and xattrs. Set
`rsync_prefix` explicitly only when its privilege boundary differs.

## CLI

The explicit `--config` examples below also work outside the repository. From
inside the repository, omit `--config` to use the discovered Nixbot inventory.
The public surface is noun-first: each movable entity owns `move`, durable
continuations use `prepare`, `run`, and `close`, and logical services cannot be
mistaken for raw systemd units. Mutations execute by default; pass `--dry` for a
strictly read-only plan. Inspection and log commands require neither. Host-agent
job submission is an internal orchestration protocol. Operators use
`job show|list|retry` to inspect or explicitly retry its durable records.

```console
abird-host-manager --config /etc/abird-host-manager.json host list
abird-host-manager --config /etc/abird-host-manager.json host list \
  --group abird --hosts 'all,-*dev*'
abird-host-manager --config /etc/abird-host-manager.json host show target
abird-host-manager --config /etc/abird-host-manager.json host logs target --since today --output text
abird-host-manager --config /etc/abird-host-manager.json host logs target --since today -f --output json
abird-host-manager --config /etc/abird-host-manager.json host ssh target
abird-host-manager --config /etc/abird-host-manager.json host exec target -- uname -a
abird-host-manager --config /etc/abird-host-manager.json host reboot \
  --group abird --hosts 'all,-*dev*' --jobs 8 --dry-run
abird-host-manager --config /etc/abird-host-manager.json host gc \
  --hosts target --delete-older-than 7d --execute
abird-host-manager --config /etc/abird-host-manager.json host gc \
  --hosts target --all-generations --dry-run
abird-host-manager --config /etc/abird-host-manager.json host clean \
  --hosts target --scope deploy --execute
abird-host-manager --config /etc/abird-host-manager.json host drain target \
  --owner maintenance-20260801 --dry-run
abird-host-manager --config /etc/abird-host-manager.json host activate target \
  --owner maintenance-20260801 --execute
abird-host-manager --config /etc/abird-host-manager.json host holds target
abird-host-manager service status zulip
abird-host-manager service logs zulip --output text
abird-host-manager service logs zulip -f --output json
abird-host-manager --config /etc/abird-host-manager.json service status zulip --host target
abird-host-manager --config /etc/abird-host-manager.json service restart zulip \
  --host target --execute
abird-host-manager --config /etc/abird-host-manager.json unit status target abird-zulip.service
abird-host-manager --config /etc/abird-host-manager.json unit logs target abird-zulip.service -f
abird-host-manager --config /etc/abird-host-manager.json unit restart target abird-zulip.service \
  --scope user --user abird --execute
abird-host-manager --config /etc/abird-host-manager.json resource describe target service:abird-zulip
abird-host-manager --config /etc/abird-host-manager.json resource logs target service:abird-zulip
abird-host-manager --config /etc/abird-host-manager.json resource logs target service:abird-zulip -f
abird-host-manager --config /etc/abird-host-manager.json resource hold show \
  target service:abird-zulip
abird-host-manager --config /etc/abird-host-manager.json resource hold acquire \
  target service:abird-zulip \
  --owner move-20260801 --execute

abird-host-manager service move zulip mail \
  --from source --to target --dry-run
abird-host-manager service move zulip mail \
  --from source --to target --execute
abird-host-manager --config /etc/abird-host-manager.json \
  host move --from old-corp --to new-corp --dry-run
abird-host-manager --config /etc/abird-host-manager.json \
  instance move abird-zulip --from-controller old-controller \
  --to-controller new-controller --from-project old-project \
  --to-project new-project --execute

abird-host-manager transaction create --spec ./multi-host-move.json --dry-run
abird-host-manager transaction create --spec ./multi-host-move.json --execute

abird-host-manager --repo-root "$PWD" host create incus example \
  --stack abird --incus-parent abird-nest \
  --incus-ipv4 10.10.100.210 --group abird --dry-run
abird-host-manager --repo-root "$PWD" host build example --execute
abird-host-manager --repo-root "$PWD" host create physical physical-example \
  --disk /dev/disk/by-id/nvme-example --boot-mode efi \
  --swap-size-mib 65536 --execute
abird-host-manager --repo-root "$PWD" host build physical-example \
  --offline-cache /media/live-usb/nix-cache --execute
abird-host-manager --repo-root "$PWD" host install example \
  --root /mnt --offline-cache /media/live-usb/nix-cache --wipe-disks --dry-run
abird-host-manager --repo-root "$PWD" host delete example --dry-run

abird-host-manager transaction prepare TRANSACTION_ID
abird-host-manager transaction run TRANSACTION_ID
abird-host-manager transaction close TRANSACTION_ID
abird-host-manager transaction close TRANSACTION_ID --rollback
abird-host-manager transaction close TRANSACTION_ID --complete --force
abird-host-manager transaction resume TRANSACTION_ID
abird-host-manager transaction resume TRANSACTION_ID \
  --supersede-failed-job
abird-host-manager transaction show TRANSACTION_ID

abird-host-manager service wipe abird-zulip \
  --host abird-gondor-zulip --id reset-zulip-target --dry-run
abird-host-manager service wipe abird-zulip \
  --host abird-gondor-zulip --id reset-zulip-target \
  --owner EXISTING_MIGRATION_ID --execute
abird-host-manager resource wipe abird-gondor-zulip service:abird-zulip \
  --id reset-zulip-target --execute

abird-host-manager --config /etc/abird-host-manager.json \
  backup create resource service:abird-zulip --from source --to source \
  --id backup-20260801 --execute

abird-host-manager --config /etc/abird-host-manager.json \
  backup create service abird-zulip --from source --to backup-host \
  --to /srv/backups/abird-zulip --id backup-20260801 --execute

sudo -n abird-host-manager --config /etc/abird-host-manager.json \
  backup create host source --to /srv/backups/abird-corp \
  --id backup-20260801 --execute

abird-host-manager backup create --spec ./heterogeneous-backup.json --execute
abird-host-manager backup show BACKUP_ID
abird-host-manager backup list
abird-host-manager backup verify BACKUP_ID
abird-host-manager backup resume BACKUP_ID --execute
abird-host-manager backup abort BACKUP_ID --execute
abird-host-manager backup restore BACKUP_ID --from backup-host --execute
abird-host-manager backup rollback BACKUP_ID --execute
abird-host-manager backup activate BACKUP_ID --execute
abird-host-manager backup delete BACKUP_ID --execute
abird-host-manager backup prune --older-than 30d --keep-last 3 --dry-run

abird-host-manager --config /etc/abird-host-manager.json job list source
abird-host-manager --config /etc/abird-host-manager.json job show source \
  --job-id backup-20260731
abird-host-manager --config /etc/abird-host-manager.json job retry source \
  --job-id backup-20260731 --execute
```

All host, service, unit, and resource log commands support `--output text|json`
for both bounded snapshots and `--follow`/`-f`; text is the default. JSON is
emitted as one journal object per line rather than an unbounded array. Both
snapshot and follow keep stdio attached through the resolved Nixbot transport,
so Ctrl-C behaves normally and a non-zero remote status fails the command.
`--lines` bounds snapshots and selects the initial followed entries. User-scoped
targets run in their declared user-manager owner's journal context; mixed
resources use one concurrent stream for the system and for each distinct user.
`host holds` lists all enforced holds and `resource hold show` inspects one
without mutation. Transaction-owned `host drain`/`activate` and
`resource hold acquire`/`activate` remain the explicit manager mutation
boundaries.

`transaction resume` is the single operator recovery command. For a projected
transaction it refreshes and validates the already-published projection, then
converges only the missing actions up to that desired phase. For a legacy
transaction it reattaches only to the exact pending action and durable job ID.
If controller or repository policy intentionally changes after a job has
terminally failed, add `--supersede-failed-job`. The manager proves the old
host-agent job is `failed`, preserves its record, and assigns the same logical
step a new attempt ID; it refuses to supersede a pending or running job.

The one-argument service form is repository-aware. Without `--stack`, it selects
the only stack declaring the service, or the unique `env = "prod"` candidate
when development or platform stacks declare it too. Ambiguous repositories fail
closed and require `--stack`. It then resolves the selected stack's active
endpoint and requires that host's evaluated agent declaration to identify
exactly one canonical resource (for example, `service:abird-zulip`). Grouped
units and user ownership remain agent metadata. `--host` bypasses placement
while still resolving the declared resource when a repository is available. Raw
systemd operations are deliberately separate under `unit <verb> HOST UNIT`; this
standalone surface cannot be confused with a logical service lookup.

`service wipe` and `resource wipe` are destructive, metadata-owned reset
operations. The manager generates or accepts one stable wipe ID. By default it
uses that ID to own the durable hold; `--owner` instead reuses an existing hold
such as the target side of an open migration. It proves every declared service
inactive, then submits one recoverable agent wipe job. The agent accepts only
its current declared data roots, preserves each root directory and exact
excluded subtrees, removes all other contents, verifies emptiness, and leaves
the resource held. Repeating the same `--id` and `--owner` is idempotent;
changing its resolved declaration is rejected as job drift. Wipe never creates a
backup and never releases or starts the resource. It is not required before
`backup restore`, whose exact-mirror copy already replaces existing contents
after creating a pre-restore safety snapshot.

Physical generation uses typed partition sizes and existing `lib/disko`
primitives. Storage and LUKS UUIDs survive forced unrelated updates and rotate
only with `--fresh-storage-ids --force`. If `--hardware-config` is omitted, the
manager probes hardware through its narrow privilege adapter. An offline build
archives the flake and caches the exact system, disko script, manager, Nix, and
installer closures before atomically publishing its manifest. Live install
resolves those exact paths with network fallback disabled, completes all
preflight checks before disk mutation, and intentionally supports only `/mnt`,
the mount root compiled into the generated disko script.

Whole-instance items capture the source and target controller, remote, project,
instance identity in the immutable transaction. `instance move --execute`
persists the record, durably reserves and stops the target, then performs the
initial verified seed. A single controller agent executes both Incus endpoints;
`--executor-controller` selects it when the source controller is not the common
executor. No manager-side Incus command or peer key is required.

`prepare` durably gates and stops the source, records whether it was originally
running, creates an owned safety snapshot, finishes the authoritative refresh,
and verifies both endpoints and the target ownership markers while leaving both
stopped. The typed stop request is part of each hold, so controller boot
reconciliation re-enforces it after Incus starts. Only `cutover` starts the
target. Rollback starts the source only when it was active before prepare;
otherwise it releases the source still stopped, while the inactive target stays
held until `close`. The safety snapshot is deleted only by `close`. Existing
unmarked targets fail closed unless the initial record explicitly uses
`--adopt-existing-target`. Before close releases the inactive endpoint, it
disables that instance's Incus autostart flag so a later controller reboot
cannot revive the old writer. Stateful VM runtime preservation remains available
to the low-level Incus primitive but is intentionally rejected by the
orchestrated move because its prepare contract proves the source stopped before
final copy. Whole-instance snapshot/export backups remain fail-closed until
their typed artifact adapter is implemented.

`backup create resource` reads the resource's `backup_consistency`. Live
resources are copied directly. Quiesced resources are durably held, proven
inactive, backed up, and then restored to the exact set of services that was
active before the hold. Services that were already stopped remain stopped. Any
backup failure leaves the hold in place for an explicit retry or recovery.

`backup create service|resource|host|instance` is the typed, record-oriented
interface. `--from` is an inventory host for service/resource items; host and
instance forms carry their source explicitly. Repeat `--to` for any mix of
inventory-host and absolute controller-directory destinations. The immutable
record expands this to an item-by-destination copy matrix and resumes only
incomplete cells. Heterogeneous sources use `backup create --spec`. The manager
resolves all data roots from source metadata unless the specification pins an
exact matching declaration; arbitrary remote paths are not accepted.
Controller-directory backups use the controller's normal inventory SSH identity
and the same `nixbot` sudo path as other native host operations.
Controller-directory execution requires local root so the receiver and
independent verifier can reproduce owners, ACLs, xattrs, and restrictive modes.
Configure the inventory identity path explicitly so the sudoed manager does not
depend on a user's home directory or forwarded agent. Every transfer uses rsync
first, falls back to tar-over-SSH, and verifies a fresh source manifest against
the destination before a quiesced source is restored. A failure leaves the
source held.

Each completed matrix cell records a typed immutable artifact: either an exact
controller directory or a host/resource/snapshot identity. `backup restore`
selects one destination that contains every item, persists that intent, and
acquires every source hold before overwriting any data. It then creates and
records a verified pre-restore safety snapshot for every item. The restored
resources remain held. `backup rollback` restores only overwritten items from
those safety snapshots, in reverse order, and also remains held. Only
`backup activate` releases the holds and starts the services that were active
before restore; it never starts a previously stopped service.

Host-to-host restore uses the same controller-brokered, direct Nixbot transfer
lane as backup. The source agent accepts only paths that correspond exactly to
the selected resource and snapshot below its configured backup namespace.
Controller artifacts are re-derived from the immutable record before restore or
deletion, so a persisted arbitrary path cannot become a deletion target.
`backup delete` durably deletes each artifact and any pre-restore safety
snapshots, then retains the record as a `deleted` tombstone. `backup prune`
groups records by their exact authority set and destinations, keeps the newest
`--keep-last` records in each group, and selects only terminal records older
than `--older-than`. Use `--dry-run` to inspect the exact selected IDs first.

Mutating migration and backup actions execute by default. Move creation `--dry`
writes no journal and asks the relevant agents only to describe and
readiness-check resources. If setup must first create an unreachable target, the
report validates setup and marks seed preflight as deferred until that target
exists. Before submitting a mutation, the manager asks the selected agent to
materialize resource policy into one complete versioned `JobSpec`, then submits
that exact document. The agent persists the specification before execution and
rejects same-ID drift.

External processes are invoked through structured Rust adapters. A shared
`CommandSpec` and `cmd!` builder preserve argv and environment boundaries, bound
captured output, and redact marked secrets. Program-specific modules own Incus,
Podman, Nix, systemd, privilege, and installer vocabulary; orchestration does
not build shell command strings.
