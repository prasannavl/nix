# abird-host-manager

`abird-host-manager` is a standalone Rust control plane for host inventory,
native SSH, service operations, durable host-agent jobs, and crash-resumable
service, whole-host, or instance moves. The former Bash host manager, Python
data migrator, and transient migration manager are retired; there is no legacy
provider or fallback path.

The manager owns ordering and its local transaction journal. Every mutation is
accepted and persisted by the selected host agent before it runs. The manager
then polls the immutable job ID. Reconnecting after an SSH failure submits or
queries the same specification; it cannot create a second mutation.

## Migration states

```text
create -> setup -> seed -> prepare -> verify -> cutover -> close
                   \          \                 \-> rollback -> close
                    \----------\--------------------> rollback -> close
```

- `create` validates immutable intent. With `--execute`, it persists the
  transaction ID before mutation, runs `setup` and `seed`, and stops before
  `prepare`; `--dry-run` writes no state and contacts no host.
- `setup` optionally provisions the target, reserves its hold before the target
  service exists, runs the controller's declarative target deployment, then
  reconciles and verifies the target hold.
- `seed` holds the target and performs a verified non-authoritative copy while
  the source remains live.
- `prepare` holds the source, verifies both writers are stopped, creates a
  verified source backup, performs the final copy, and leaves both sides held.
- `verify` repeats the prepared-data verification without releasing either side.
- `cutover` runs the controller's declarative placement/ingress deployment while
  both resources remain held, then activates and verifies only the target.
- `rollback` is the only transition that activates the source. If target
  activation may have occurred, it first performs a verified reverse copy.
- `close` ends the rollback window and releases the inactive endpoint hold
  without starting it.

Nothing automatically starts after `prepare`, timeout, failure, or disconnect.

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
or credentials. JSON is used only when an operation needs additional runtime
policy such as a local transfer broker, polling timeouts, or deployment routes.
A JSON configuration contains:

```json
{
  "schema_version": 1,
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
`deploy`, plus the typed `nixbot_deploy` controller capability. A Nixbot request
keeps the real connection `host` separate from its optional `nix_config`; the
corresponding Nixbot CLI uses `--host`/`--hosts` and `--nix-config`. For
reusable move inventories, `{"endpoint":"source"}` and `{"endpoint":"target"}`
resolve the selected host's `nixbot_deploy` request; literal requests remain
available for fixed infrastructure or ingress routes. Only declarative boundary
actions are routed: setup requires `deploy-target-gated`, cutover requires
`deploy-cutover`, rollback requires `deploy-rollback`, and `provision-target` is
optional. A controller host agent can therefore continue an accepted
Nixbot/repository deployment if the manager disconnects.

Seed, final copy, reverse copy, verification, and backup are not profiles. The
manager resolves source and target data roots by stable name, requires identical
exact-subtree exclusions, and persists the immutable path mapping in its
transaction before the first copy. Legacy `data_paths` remain an identical-path
shorthand. The manager then submits the mapping and source/target endpoints to
the configured local controller agent. Its durable broker job delegates the
existing Nixbot identity through a short-lived forwarded SSH agent; rsync and
tar payloads travel directly source-to-target. No peer key, target-side
credential, controller staging tree, or additional listener is required.
`broker_ssh_args` describes reachability from within the managed network
independently from the manager's ordinary SSH path.

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
continuations are named transaction phases, and logical services cannot be
mistaken for raw systemd units. Every direct mutation requires exactly one of
`--execute` or `--dry-run`; inspection and log commands require neither.
Host-agent job submission is an internal orchestration protocol. Operators use
`job show|list|retry` to inspect or explicitly retry its durable records.

```console
abird-host-manager --config /etc/abird-host-manager.json host list
abird-host-manager --config /etc/abird-host-manager.json host list \
  --group abird --hosts 'all,-*dev*'
abird-host-manager --config /etc/abird-host-manager.json host show target
abird-host-manager --config /etc/abird-host-manager.json host logs target --since today
abird-host-manager --config /etc/abird-host-manager.json host logs target --since today -f
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
abird-host-manager service logs zulip -f
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

abird-host-manager --config /etc/abird-host-manager.json \
  service move abird-zulip mail --from source --to target --execute
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

abird-host-manager transaction seed TRANSACTION_ID --execute
abird-host-manager transaction prepare TRANSACTION_ID --execute
abird-host-manager transaction verify TRANSACTION_ID --execute
abird-host-manager transaction cutover TRANSACTION_ID --execute
abird-host-manager transaction rollback TRANSACTION_ID --execute
abird-host-manager transaction resume TRANSACTION_ID --execute
abird-host-manager transaction close TRANSACTION_ID --execute
abird-host-manager transaction show TRANSACTION_ID

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

Log snapshots remain structured, bounded agent calls. `--follow`/`-f` instead
uses the same resolved Nixbot transport but keeps stdio attached end to end, so
Ctrl-C behaves normally and a non-zero remote status fails the command.
Streaming follow output is intentionally not wrapped in manager JSON.
User-scoped targets run in their declared user-manager owner's journal context;
mixed resources use one concurrent stream for the system and for each distinct
user. `host holds` lists all enforced holds and `resource hold show` inspects
one without mutation. Transaction-owned `host drain`/`activate` and
`resource hold acquire`/`activate` remain the explicit manager mutation
boundaries.

The one-argument service form is repository-aware: it resolves the stack's
declared active endpoint, then requires that host's evaluated agent declaration
to identify exactly one canonical resource (for example, `service:abird-zulip`).
Grouped units and user ownership remain agent metadata. `--host` bypasses
placement while still resolving the declared resource when a repository is
available. Raw systemd operations are deliberately separate under
`unit <verb> HOST UNIT`; this standalone surface cannot be confused with a
logical service lookup.

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
held until `close`. The safety snapshot is deleted only by `close`. Existing unmarked targets fail
closed unless the initial record explicitly uses `--adopt-existing-target`.
Before close releases the inactive endpoint, it disables that instance's Incus
autostart flag so a later controller reboot cannot revive the old writer.
Stateful VM runtime preservation remains available to the low-level Incus
primitive but is intentionally rejected by the orchestrated move because its
prepare contract proves the source stopped before final copy. Whole-instance
snapshot/export backups remain fail-closed until their typed artifact adapter
is implemented.

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

Mutating migration and backup actions require `--execute`. Creation `--dry-run`
writes no journal and contacts no host. Before submitting a mutation, the
manager asks the selected agent to materialize resource policy into one complete
versioned `JobSpec`, then submits that exact document. The agent persists the
specification before execution and rejects same-ID drift.

External processes are invoked through structured Rust adapters. A shared
`CommandSpec` and `cmd!` builder preserve argv and environment boundaries, bound
captured output, and redact marked secrets. Program-specific modules own Incus,
Podman, Nix, systemd, privilege, and installer vocabulary; orchestration does
not build shell command strings.
