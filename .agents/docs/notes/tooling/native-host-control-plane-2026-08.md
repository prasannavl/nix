# Native Host Control Plane, 2026-08

## Outcome

Pvl adopts the native Rust host-control architecture from Abird through
`fd3f9cda`:

- `abird-host-agent` owns durable host-local holds, accepted jobs, service and
  Incus lifecycle, logs, readiness, transfers, backups, and recovery;
- `abird-host-manager` owns operator intent, repository inventory, SSH
  transport, transaction ordering, host workflows, moves, backups, and rollback
  decisions; and
- native `systemd.user` services plus generated managed/ready targets own
  ordinary switch-time convergence.

The retired `systemd-user-manager`, Bash `host-manager`, Python `data-migrator`,
and runtime `migration-manager` have no compatibility fallback. Historical notes
remain indexed as superseded evidence, not executable guidance.

## Pvl Adaptations

The cumulative agent package and shared Nix module files remain byte-identical
to Abird. Pvl owns these narrow integration differences:

- the root Cargo workspace and lockfile contain only Pvl packages plus the two
  host-control tools;
- `pkgs/manifest.nix` retains the Pvl package catalog while exporting
  `abird-host-agent` and the `abird-host-manager` root app;
- the common host module enables the agent for physical and Incus Pvl hosts;
- the root flake retains a direct host-agent import because Pvl physical hosts
  use `machineProfile = null`, while Nixbot uses package module discovery;
- logical service lookup defaults to stack `pvl`, not `abird`; and
- generated Pvl host modules import `../common/pvl.nix`.

No Abird/Gondor migration inventory, host topology, checked-in secrets, or
application-control-plane packages are imported by this port.

## Follow-up Capabilities

The post-`bf4e406a` audit adds cumulative native behavior without importing
Abird migration inventory or application-controller code:

- cold held targets are valid deploy-health states, and image preparation for a
  not-yet-created service owner defers to activation;
- held resource data can be wiped only through a durable, hold-checked job;
- agent and manager logs share symmetric text/JSON snapshot and follow modes;
- deferred jobs use a consumable wakeup marker, broker endpoints are pinned,
  move progress is durable, and matching pre-prepare moves can resume safely;
- live transfers distinguish source drift from destination damage, require
  independent verification, and execute receiver tools from the configured agent
  closure; and
- Nixbot repository authentication is scoped per repository, while SSH agent
  forwarding stays denied globally except for the explicit `nixbot` user.

## Ownership Rules

- Holds are persistent host-agent state. Disconnects and elapsed time never
  infer release, activation, cutover, or rollback.
- Release alone never starts a resource. Explicit durable activation is the
  start boundary.
- The manager and agent stay separate: cross-host authority belongs to the
  manager; accepted host-local enforcement must survive without it.
- Pvl host creation continues to edit the canonical `hosts/default.nix`,
  `hosts/nixbot.nix`, `data/secrets/default.nix`, and host module directories.
- Exact shared package bytes are preferred. Pvl policy stays limited to root
  workspace/catalog wiring and the two manager defaults above.

## Validation Contract

Validate the two Rust packages, the host-agent Nix module and transfer fixtures,
Podman Compose integration, flake manifest/registry checks, nixbot, and
representative physical plus Incus host evaluations. Finish with a source scan
for active references to retired tools and a file-level parity comparison
against `abird/master`.
