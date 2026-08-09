# abird-host-agent

`abird-host-agent` is a standalone Rust executor for persistent service holds,
systemd lifecycle and logs, readiness, data copy and verification, backups,
atomic route state, infrastructure provisioning, NixOS activation, and durable
jobs. It has no runtime dependency on an Abird checkout or a live manager.

The optional NixOS module generates `/etc/abird-host-agent/resources.json`. Each
resource can declare:

- system or user services, shorthand `dataPaths`, named `dataRoots` with exact
  relative-subtree exclusions, and live or quiesced backup consistency;
- path, TCP, and HTTP readiness checks;
- local or remote transfer profiles;
- atomic file states with service reloads;
- Incus-compatible instance profiles;
- NixOS system closure activation profiles;
- fixed-argv operations for future provider-specific extensions.

Service modules should derive lifecycle units automatically. They should derive
data roots only when ownership is unambiguous; otherwise the service declares
one explicit consistency root. Podman Compose, for example, derives absolute
managed directories with `once = true`, while `hostAgentDataPaths` can replace
them with one parent root such as `/var/lib/abird/zulip`.

NixOS callers use typed logical names rather than constructing protocol IDs:

```nix
services.abird-host-agent = {
  services.zulip = {
    units = [
      {
        scope = "user";
        user = "abird";
        unit = "abird-zulip.service";
      }
    ];
    dataRoots.zulip = {
      path = "/var/lib/abird/zulip";
      excludes = ["cache" "tmp/generated"];
    };
  };
  instances.example.dataPaths = ["/var/lib/incus/instances/example"];
  extraResources."group:example".operations.inspect = ["/bin/true"];
};
```

The module normalizes those declarations to canonical `service:zulip` and
`instance:example` IDs. The agent CLI, generated manifest, holds, jobs, and
journals use those canonical IDs. `extraResources` is the explicit escape hatch
for uncommon resource kinds and accepts complete IDs.

All profile data is copied into the accepted job specification. A later NixOS
generation cannot change a running or retried job.

## Holds and lifecycle

```console
abird-host-agent status
abird-host-agent hold acquire --resource service:zulip --owner tx-123
abird-host-agent hold status --resource service:zulip --json
abird-host-agent hold release --resource service:zulip --owner tx-123

abird-host-agent logs --lines 200 --since today
abird-host-agent logs --lines 200 --since today --follow
abird-host-agent logs --resource service:zulip --follow
abird-host-agent logs --unit nginx.service --lines 200
abird-host-agent logs --unit zulip.service --scope user --user abird --follow
abird-host-agent unit start --scope system --unit nginx.service
abird-host-agent unit restart --scope system --unit nginx.service
abird-host-agent unit reload --scope system --unit nginx.service
abird-host-agent resource describe --resource service:zulip
abird-host-agent resource restart --resource service:zulip
abird-host-agent resource reload --resource service:zulip
abird-host-agent resource ready --resource service:zulip
```

Log snapshots are bounded structured results and support `--json`. Follow mode
streams `journalctl` directly until interrupted or the journal process exits; it
does not buffer an unbounded result and therefore cannot be combined with
`--json`. One `logs` command owns host, resource, and explicit-unit selection;
the selectors are mutually exclusive. Named user units execute through `runuser`
in that user's journal context. A mixed resource follows system units and each
distinct user context through separate concurrent journal processes; units are
combined only when they share the same execution identity. Declarative
user-scoped units must name their user-manager owner. A direct standalone
`unit logs --scope user` without `--user` deliberately uses the agent process's
current user context.

Acquisition persists the hold before stopping declared units. Release never
starts a service. `activate` is the only transaction operation that releases a
matching hold and starts its snapshotted services. Resource restart and reload
operate the complete declared service group and fail before invoking systemd
while the resource is held.

## Durable operations

The stable machine interface accepts one complete, versioned `JobSpec`. This is
the same immutable document stored for retries; `-` reads one bounded JSON
document from stdin.

The manager may first use a hidden, read-only materialization call to resolve a
resource-scoped intent against this host's manifest. Mutation still crosses the
boundary only as the resulting complete `JobSpec`; the selector form cannot
silently change an already accepted job.

```console
abird-host-agent job submit --spec ./job.json --defer
abird-host-agent job submit --spec - --defer < ./job.json

abird-host-agent job show --job-id backup-20260801 --json
abird-host-agent job retry --job-id backup-20260801
```

Jobs are atomically persisted before execution. Same-ID/same-spec submissions
are idempotent; a changed specification is rejected. A boot service resumes
pending or interrupted jobs. Running transfers persist engine, stage, entry, and
byte progress in the job record. Source transfer processes emit framed JSON
progress on stderr; the controller parses it concurrently with bounded
diagnostics and keeps final structured JSON on stdout.

Local backups store job-scoped snapshots below the manifest's backup root. A
quiesced local backup is rejected unless its transaction owns the resource hold
and every declared service is inactive. Backup destinations are exactly
reconciled on retry, then treated as immutable after success. Data-only
resources may still acquire a persistent hold even when they declare no systemd
units; the hold remains the cold-start and writer-ownership gate.

Manager-submitted restore jobs derive the source snapshot and target data roots
again from the current manifest, require the same transaction to own the hold,
prove every declared service inactive, replace the target, and independently
verify it. Snapshot deletion also re-derives one exact
`backup_root/resource-digest/snapshot` path at execution time and is idempotent.
Neither operation accepts a caller-supplied filesystem path.

Cross-host copies are controller-brokered durable jobs. Only the controller
manifest contains `broker_transfer`, which points at its existing Nixbot
identity. For each job the controller agent starts a private ephemeral
`ssh-agent`, forwards its socket to the source session, and destroys it on
completion. Before forwarding, the controller reloads the identity with
host-bound constraints permitting only controller-to-source and that bound
source session-to-target. The key never appears on either peer. The source then
runs rsync directly to the target, so bulk bytes do not traverse or stage on the
controller. Before delegation, the controller reads the target's public host key
over its authenticated SSH channel; the source pins that key in a private
job-runtime known-hosts file. Target rsync and tar receivers validate that the
destination is an exact declared data root or below the agent-owned backup root.
For cross-host restore, the backup host additionally proves that every source
path is the exact snapshot counterpart of its declared target root before
starting rsync or tar.

Transfer jobs use rsync first with archive, hard-link, ACL, xattr, numeric
ownership, partial-file, and delete-before semantics. Deleting first lets the
archive pass restore directory metadata last. If rsync fails:

- local transfers use the native recursive filesystem engine with atomic files,
  hard links, ownership, modes, timestamps, xattrs/ACLs, and scoped deletion;
- remote transfers stream GNU tar over SSH with ACL, xattr, numeric-owner, and
  permission preservation.

Both paths independently manifest source and destination afterward. Verification
compares relative path bytes, type, size, mode, uid/gid, timestamps, xattr
digest, file SHA-256, and symlink target. A mismatch fails the durable job with
bounded mismatch details and full-tree digests.

Named data-root excludes are normalized relative subtrees, not globs. The same
filter is applied to rsync, native copy, tar, source/destination manifests,
verification, and deletion. An excluded subtree already present at the
destination is never deleted. Broker jobs persist the controller-resolved named
source/target mapping, so retries cannot pick up changed declarations.

Rsync output is captured as bytes so non-UTF-8 names remain valid, and retained
stdout/stderr is bounded with explicit truncated-byte counts. Fallback progress
distinguishes the native filesystem and tar-over-SSH engines.

File-state jobs atomically persist content before reloading every declared
consumer. Retries reload even when the file already matches, because an earlier
attempt may have durably replaced the file but lost the reload.

The `JobSpec.operation` tagged union carries resource lifecycle, transfer,
backup/restore, file-state, instance, deployment, and allowlisted named
operations. Backup restore snapshots the previously active declared services,
validates that each belongs to the held resource, releases the hold, and starts
only that subset as one durable job.

For rolling deployment compatibility, the previous `service`, `data`,
`job status`, selector-style `job submit`, `hold declare/apply`,
`job run-pending`, and maintenance argv continue to parse but are hidden from
normal help. New boot integration uses the hidden `_reconcile` namespace, and
authenticated peer traffic uses the hidden `_transport` namespace. These are not
operator interfaces: the manager owns cross-host selection and sequencing, while
the agent owns durable host-local execution and verification.

Durable instance jobs accept either an allowlisted `--provision` profile or a
JSON `--migrate-instance` request. Native Incus migration supports seed/prepare
snapshots, refresh of an owned target, local or remote locations, cross-project
copy, compatibility marker checks, target-pool validation, pull/push/relay copy,
graceful stop policy, seed consistency policy, and optional VM runtime-state
preservation. Seed never stops or starts a writer. Prepare stops running source
and target instances before the authoritative snapshot and never restarts
either; activation belongs only to explicit cutover or rollback orchestration.

External command execution uses structured argv rather than a shell. Executable
override flags remain available as environment-backed test and packaging seams
but are hidden from normal help. The shared `CommandSpec`/`cmd!` layer owns
bounded capture, environment, current directory, absolute executable validation,
and redaction. Small adapters under `programs/` own Incus, Podman, Nix, Nixbot,
and systemd commands, while streaming transfer code owns only the pipes required
for rsync, tar, and SSH.
