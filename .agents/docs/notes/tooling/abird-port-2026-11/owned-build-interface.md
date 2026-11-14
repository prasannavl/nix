# Experimental owned-build interface

Neutral reference for the [November port](README.md), not an enablement recipe
or an installed-service acceptance report. Adapted from source operator notes at
`7ace9dcaf8a78897e28bf3fc571e19882b198bb2` (ledger `n2237ace9dcaf`) and
caller-profile notes at `070011e2923ebdb16370bbfbba31876c47584002`
(`n225070011e29`). Commands and options below follow the imported
implementation, not historical qualification receipts. No live rollout is
authorized or performed by this port.

## Gates and role separation

- `auto` still selects **Nix**. Only explicit `--strategy=agent` selects the
  experimental backend; it emits a warning. The installed manager supports
  `fleet build`, `fleet dev-build` and `fleet deploy` on that backend, not
  `fleet run`. Packaged Nixbot delegates to the same manager; prefer installed
  entries, not a raw checkout-script bootstrap.
- `services.abird-host-agent.buildExecutor.enable` and its separate
  `acceptSubmissions` gate default to false. Enablement alone neither
  initializes authority nor opens submission. Bootstrap is explicit; no
  automatic initialization, adoption or repair is promised.
- `services.abird-host-manager.buildController.enable` defaults to false. It
  installs caller metadata and retention-root leaves, not an executor or a grant
  to activate hosts. It does not enable the parent reconciliation service.
- A caller-only host with explicitly allowed `sourceRoots` gets the separate
  capture role. That role needs its own approved relay, budgets and
  source/helper limits; it is not a scheduler or native build daemon. Colocated
  capture uses the independently enabled executor instead. Do not enable both
  capture roles.
- Ordinary host-agent enablement does not opt a host into owned builds. Import
  the agent module's option namespace when composing caller profiles; the
  repository already registers it. No actual host is opted in by this guide.

Code:
[strategy](../../../../../pkgs/tools/abird-host-agent/src/build_executor/strategy.rs),
[dispatch](../../../../../pkgs/tools/abird-host-manager/src/fleet/build_backend/mod.rs),
[executor](../../../../../lib/services/abird-host-agent/build-executor/default.nix),
[executor options](../../../../../lib/services/abird-host-agent/build-executor/options.nix),
[controller](../../../../../lib/services/abird-host-manager/build-controller.nix),
[capture](../../../../../lib/services/abird-host-manager/capture.nix).

## Generated callers: routing is not admission

Prefer `services.abird-host-manager.buildController.callers.<account>` to
handwritten bootstrap JSON. Accounts must already exist with fixed, distinct,
nonroot UIDs. The module generates immutable `/etc/abird-owned-fleet/<uid>.json`
metadata and matching state/source bindings; it creates no caller account or SSH
key. Legacy explicit `callerBootstraps` remain supported; conflicting generated
bindings fail rather than silently overriding authority.

| Field                                         | Source or meaning                                                                                                                                         |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `callers.<account>.repositoryId`              | Required identity approved by the builder; not an arbitrary repository URL.                                                                               |
| `inventory`                                   | Defaults to trusted `repository.inventory` from NixOS special arguments; explicit override allowed. Used for routing, not source evaluation or admission. |
| `hostId`, `fabricId`                          | Default to `networking.hostName` and `fleet`; colocated control must name its inventory host. Neither is an authentication grant.                         |
| `callers.<account>.stateHome`                 | Defaults to the account home plus `/.local/state`; must match the caller's actual XDG state base.                                                         |
| `callers.<account>.sourceRoots`               | Defaults to `[]`: configured-repository CI only, not arbitrary working-checkout capture. Declare only approved bounded subtrees, not whole homes.         |
| `callers.<account>.knownHostsFile`            | Defaults to existing `/etc/ssh/ssh_known_hosts`; no generated trust or TOFU.                                                                              |
| `callers.<account>.credentials`               | Inventory-reference to existing absolute runtime-path map; no secret contents or automatic decryption.                                                    |
| `callers.<account>.nix.maxJobs`, `.nix.cores` | Default to null/omitted; resolve once from authenticated builder policy at admission. Explicit values cannot exceed that policy.                          |
| `callers.<account>.nix.substitute`            | Defaults to true; ordinary signature enforcement remains.                                                                                                 |

Local versus remote control is derived from executor enablement, not a
caller-authored switch. Reconnect retains the original admitted request and
ceilings. Generated profiles never grant detached observer ownership.

On the builder, `buildExecutor.principals.<account>.uid` defaults to that
declared account's UID, and `issuer` to its account name. Admission still
requires explicit principals, approved `repositories`, stable `identity`,
workload UID/GIDs, `resources`, `controlReserve`, `sourceLimits`, deadlines and
other required
[executor options](../../../../../lib/services/abird-host-agent/build-executor/options.nix).
Input-only `inputPrincipals` need separate accounts and an explicit control
issuer; they are not ordinary SSH/control identities.

For remote working-source capture, `buildController.capture` additionally
requires `relayUser`, `relayKeyFile`, `memoryMax`, `tasksMax`, `cpuPercent`,
`maxSeconds` and `sourceLimits`. `relayPort` defaults to 2022 and must match the
builder's admitted input endpoint, distinct from ordinary control SSH.
`runtimePackages` declares extra offline helper dependencies; installing tools
on ambient PATH is not a read grant. Keys remain runtime references, never store
contents.

Inventory membership supplies no admission, resource reservation, cache trust or
signing policy. This reference intentionally supplies no enabled configuration:
all those operator decisions and platform qualification must precede any
rollout. The existing local GC-coordination capacity policy is not an
owned-executor capacity default.

## Operator surface

Read the installed command reference without submitting work:

```sh
abird-host-manager fleet build-controller help
```

Canonical durable-run prefix: `abird-host-manager fleet build-controller`.
`fleet owned` remains its compatibility alias. Use the returned original run ID;
never create another run merely because a response was lost.

| Suffix                                          | Purpose and limits                                                                                                  |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `status RUN`                                    | Read builder status and separate caller liveness.                                                                   |
| `events RUN [--after ATTEMPT=SEQUENCE]`         | Read bounded lifecycle events.                                                                                      |
| `logs RUN [--cursor ATTEMPT=GENERATION:OFFSET]` | Read bounded diagnostics, not arbitrary build stdout/stderr; gaps are explicit.                                     |
| `attach RUN [--wait-seconds N]`                 | Continue the original run's polling/input workflow, not replacement submission or delivered-source replay.          |
| `cancel RUN [--wait-seconds N]`                 | Persist forward withdrawal and wait for observed settlement; not an immediate kill/success guarantee.               |
| `consume RUN [--wait-seconds N]`                | Reconcile the original signed acquisition/ACK; a retained Deploy may then run deployment phases. **Not read-only.** |
| `retire RUN [--wait-seconds N]`                 | Observe required builder cleanup and retire caller state/roots; not forced deletion of uncertain state.             |

`--wait-seconds` is an observation bound (1–3600, default 300), not a fresh
execution or stop-grace budget. Interrupting observation is not remote
cancellation. The low-level typed-intent submission API is not a substitute for
installed profiles. See the actual
[command implementation](../../../../../pkgs/tools/abird-host-manager/src/fleet/build_backend/agent/commands.rs).

Working-checkout Build/Deploy and DevBuild retain their source contracts;
missing capture authority is not permission to fall back to CI. Thin CI uses the
ordinary `--ci-trigger` forwarding path with `--sha` and optionally
`--dirty-staged`: operator Git/inventory/SHA/patch preprocessing remains outside
owned execution; the receiving controller's configured repository, evaluation
and realization are admitted. A thin forwarding caller needs no local capture
profile, but the receiver still needs installed, admitted profiles. DevBuild
rejects `--sha` and `--ci-trigger`. Independent/detached CI observer ownership
remains unavailable.

## Native and settlement boundaries

- The
  [native adapter](../../../../../pkgs/tools/abird-host-manager/native/default.nix)
  supports **Nix 2.34.9 / adapter ABI 3**, not arbitrary 2.34.x. Packaging omits
  it for unsupported versions while retaining ordinary manager operation.
  Executor enablement checks that the adapter uses the exact
  `config.nix.package`; it does not select a different system Nix. Verify the
  consumer's Nix/adapter pairing too: caller-profile evaluation alone is not
  compatibility evidence.
- Offline caller helpers require Landlock ABI9 plus the installed namespace,
  process and cgroup protections. Do not weaken these or change host pins merely
  to make an example work. A dedicated Nix-untrusted UID is not a per-operation
  daemon sandbox: upstream still permits that native client to request GC.
- Submit, input-delivery and stop ACKs are not execution settlement. Builder
  success, signed acquisition, consumer ACK, source-protection release and
  retirement are separate observations. An ACK is a bound consumer statement,
  not independent proof of signature verification or retention.
- `settlement_scope` is `builder`. Caller exit/lock release, transport success,
  closed diagnostics or metadata retirement do not certify target activation or
  rollback. Cancellation of a Deploy whose build succeeded can remain
  unconfirmed even after builder settlement and caller exit. Do not invent that
  proof or replay realization to resolve uncertainty.
- Signed handoff depends on explicitly configured cache/trust and verified
  acquisition. Nothing here promises cache availability, uninterrupted
  publication, physical capacity reservation or exhaustive crash recovery.

## Required qualification

Run from the candidate root only after source inclusion and build authorization;
these are required checks, **not claims that this documentation ran them**.
[Registration](../../../../../lib/tests/default.nix) contains the four Linux
checks:

```sh
nix build --no-link .#checks.x86_64-linux.lib-build-executor-control
nix build --no-link .#checks.x86_64-linux.lib-nix-builder-containment-vm
nix build --no-link .#checks.x86_64-linux.lib-nix-builder-launch-gate-vm
nix build --no-link .#checks.x86_64-linux.lib-build-agent-workflow-vm
```

- Control: defaults, generated callers, invalid bindings and installed CLI
  paths.
- Containment/launch gate: real daemon ancestry, ingress fencing, supervisor
  loss, GC and cleanup boundaries; fault injectors alone do not qualify full
  Build.
- Complete workflow: local/remote capture and signed handoff, thin CI,
  reconnect, cancellation, retirement, OOM recovery, trust failure/abandonment
  and retained deployment/rollback. It also executes the privileged production
  namespace probe **inside the disposable VM**; a skipped host-side test is not
  equivalent.

Also run the package libraries/integration tests and Bash frontend regressions:

```sh
cargo test --locked --offline -p abird-host-agent -p abird-host-manager --lib --tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  --start-directory pkgs/tools/nixbot/tests --pattern 'test_*.py'
```

The manager's ignored
[`native_development_preflight_preserves_foreign_result_entries`](../../../../../pkgs/tools/abird-host-manager/src/fleet/build_backend/agent/acquisition/native.rs)
requires an explicit run with `ABIRD_TEST_ACQUISITION_LIBRARY` pointing to the
matching built ABI3 library. Its full test name is
`fleet::build_backend::agent::acquisition::native::tests::native_development_preflight_preserves_foreign_result_entries`;
select it with Cargo `--lib` and test-harness `--exact --ignored`. Ordinary
package builds and unprivileged Rust tests do not establish native/VM
acceptance.

Retain existing `lib-abird-host-agent`, `lib-abird-host-manager`,
`lib-nix-builder-gc-coordination` and `pvl-nix-builder-gc-defaults` checks, plus
the repository formatting/lint and no-IFD evaluation gates. Track actual results
and review findings separately; source receipts or a successful evaluation never
authorize live enablement.
