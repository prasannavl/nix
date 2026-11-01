# Incus proxy rollback compatibility — 2026-10

## Scope and custody

- Bases: z `2657e67f93045bcdc8b723fc53e5066e7f4d5f09`; nix
  `4b2d4c71acf382e6fb4799ab41bf934391e04e1b`.
- Local implementation/testing only. No live probes, activation, credentials,
  commits, pushes, input updates or lifecycle-tag changes.
- Tictactoe loses only default-group membership in z. Its inventory identity,
  explicit targeting and stopped/capacity declarations remain intact. The
  default group contains the other nine declared Gondor guests; dependency
  selection still supplies their parent.
- Shared Incus changes/tests/fixtures are identical. Host-manager, host-agent,
  Nixbot implementation/generic tests and service modules were already
  identical. Final scope: 154 common paths, 151 byte/type/mode-identical. Three
  child `flake.nix` wrappers retain the approved artifact-sharing policy
  difference; z retains its three private Nixbot ledger paths. All 12 Incus
  paths match. This is source parity, not cross-repository lockfile,
  dependency-graph or binary equality.

## Wire contract

- Keep v1 `user.nixos-meta.configHash` at the applied pre-hotplug hash.
  Proxy-only changes never replace it with a proxy-free hash or a newly declared
  proxy hash.
- `user.nixos-proxy-meta` version 1 stores `controller`, proxy-free applied
  `configHash`, original `legacyConfigHash` and sorted owned `proxyDevices`.
- Read/write through one codec. Validate controller, legacy-hash binding, schema
  and owned-name shape before lifecycle/adoption. Reserve ownership before
  device mutation; write both metadata keys in one native config-set operation
  when both change. Preserve retryable partial reservations.
- Old helpers see their original v1 contract and leave the separate sidecar
  untouched, including during GC. A later fixed helper can retire proxies even
  after old code rewrites the main metadata.
- New GC changes removal/suspend policy only. It cannot overwrite applied
  hashes, tags, disk/network/limit ownership or the proxy ledger with desired
  state. Current-helper takeover releases both metadata keys.
- Unsafe preview v1 metadata containing `proxyDevices`, malformed/orphaned
  sidecars and mismatched bindings fail before mutation, including with adoption
  or changed recreation intent. Recovery needs the actual historical state;
  never fabricate a hash or bump `recreateTag` to get past refusal.

## Evidence

- Actual pre-fix helper: all eight initial downgrade scenarios fail as intended.
  Four recreate guests with existing proxies; four lose ownership of newly added
  proxies after rollback. Not a simulated old decision function.
- Fixed native suite: **39 passing tests**. Transition matrix has 16 scenarios:
  live/full reconciliation, running/stopped, existing/no original proxy, and
  legacy-created/fixed-created guests. Includes real old lifecycle and GC code,
  new GC, idempotency, identity preservation and re-upgrade cleanup.
- Additional guards cover ambiguous legacy migration, foreign/profile/type
  conflicts, corruption, partial failures, ETag retry, takeover, explicit
  recreation and pending declarative immutable drift.
- Fresh-guest idempotency exposed a missing inherited-NIC override in fake
  Incus. The fake now models profile `eth0` and actual override persistence;
  assertions were retained, not narrowed to hide the extra mutation.
- Both roots requested the same fresh Nix helper derivation: **39 passing
  tests**, realized once and reused by the other request. Fresh Nix module
  checks also pass lifecycle-trigger invariance and Nix/Bash/old-decoder wire
  round trips.
- The actual archived Nix module produced the frozen synthetic state, including
  Unicode/quotes/newlines. Its hash is
  `24e1c04647bae19fff6d00193a2ea4f1374bdf86cc0420dde2686eca634365ac`. Tests
  require the current v1 projection to equal that historical wire state. Fixture
  provenance: `lib/incus/tests/fixtures/README.md`.
- Actual pre-fix GC fails both applied-state preservation controls. The old
  inventory fails the exact nine-member default-group assertion and includes
  Tictactoe as the tenth member. Positive inventory check passes.
- Unqualified `nix --offline fmt` and `nix --offline run .#lint -- --base HEAD`
  pass in both worktrees. Root formatting is required here: `--project` alone
  skips root-managed files.
- Host-manager/agent Rust tests and Nixbot helper/runtime tests reuse successful
  outputs; the `lib-nixbot` aggregate checks execute fresh. These are not fresh
  Rust/Nixbot test runs. Public validation uses `lib-nixbot`; the additional
  `nixbot-helper` root alias is z-only, not an implementation difference.
- `nix --offline flake check --option eval-cache false --all-systems --no-build`
  passes: **217 z checks** (109 x86 Linux / 108 ARM Linux), **185 nix checks**
  (93 / 92). No Darwin checks; package evaluations are not builds or live tests.
- Final gate logs: `/tmp/pi-bg/job-2852102-912.log` (z), `job-2852102-913.log`
  (nix format/lint, followed by an invalid z-only alias), `job-2852102-915.log`
  (correct public outputs and all-system pass).
- Protected notes/override, inputs/locks/workspace policy and original main
  HEADs remain unchanged. Only owned fixes, fixtures and task documentation are
  delivered; no deployment or commit is implied.
- Independent z fetch advanced `origin/master` and `origin/HEAD` from
  `6c84ce9ed2223b4aa35a1ef47a5c2479ae3bfe9c` to
  `00f312ec8fc66ed9016ab980f81792876d29f3ff`. Reflog reports
  `fetch: fast-forward`; this task ran no fetch/push and did not move either
  main HEAD or recovery refs.

## Operational limits

- Proxy-only migration no longer triggers guest recreation on rollback to the
  matching pre-hotplug declaration. This does not make arbitrary immutable
  changes or explicit recreation tags nondestructive.
- An old helper does **not** undo live proxy edits. If ports must revert, first
  converge the old proxy declaration using the fixed helper, then roll back the
  generation. Do not use the unsafe intermediate preview as a rollback target.
- No zero-downtime first-upgrade claim: helper/unit changes and unrelated host
  changes can still restart services. Native proxy edits can interrupt their
  connections without recreating the guest.
- Synthetic helper/module checks are not live Incus, cold-start, physical-store,
  cache-retention, SSH admission or full rollback acceptance. Preserve health
  checks and automatic rollback; stop on refusal rather than recreating Nest.
- Tailscale/unstable remains held as a separate final approved update. Legacy
  Gondor CI retirement remains separately authorized.
