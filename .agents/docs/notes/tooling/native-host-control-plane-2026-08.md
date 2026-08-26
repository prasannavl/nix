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

The host-manager package is additionally synchronized through Abird's `3588b7b7`
failed-job supersession fix and the subsequent shared repository-neutral
discovery refactor.

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
  use `machineProfile = null`, while Nixbot uses package module discovery.

The complete `pkgs/tools/abird-host-manager/**` package is byte-identical
between Pvl and Abird. Logical service lookup discovers the unique production
stack from repository metadata, and generated host modules select
`hosts/common/<org>.nix` from the injected `stack.org`.

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
- terminal failed jobs can be preserved and explicitly superseded with a new
  durable attempt ID;
- live transfers distinguish source drift from destination damage, require
  independent verification, and execute receiver tools from the configured agent
  closure; and
- Nixbot repository authentication is scoped per repository, while SSH agent
  forwarding stays denied globally except for the explicit `nixbot` user.

Controller-owned deployments are deliberately single-host and single-lane. The
agent adapter passes one build-plan, build, deploy, and verify job to Nixbot,
bounding controller memory independently of operator-oriented defaults. Nixbot's
runtime closure owns `flock` through `util-linux`; controller system packages
are not an implicit dependency.

Durable controller-job recovery defers while Nixbot's host-local action lock is
held. The module uses a consumable wakeup marker plus a bounded retry timer, and
may pass one typed, immutable `configOverride` path as
`NIXBOT_CONFIG_OVERRIDE_PATH`. The agent rejects a missing or relative override
instead of exposing arbitrary environment injection. Pvl does not add Abird's
Gondor routes, guest-memory policy, or host-specific override.

Projected reconciliation also keeps routing and recovery authority explicit:

- deploy cutover and rollback execute through the route derived from the exact
  projected source or target resource rather than a stale base-inventory route;
- the controller module can give operator-dispatched commands and reconciliation
  units one `configOverride`, and only projection IDs listed in
  `failedJobSupersessionProjections` receive `--supersede-failed-job`;
- reconciliation always retains `--execute`; supersession is an additional
  authorization, not a dry-run escape; and
- the flake derives every projection endpoint and effect-executor host,
  validates it against Nixbot inventory, and exports those hosts as controller
  deployment dependencies. Nixbot merges that evaluated edge set before
  ordering, so `--ci-first` cannot activate a controller ahead of its projection
  hosts.

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
  workspace, catalog, flake, host, and stack wiring outside the shared package.

## Validation Contract

Validate the two Rust packages, the host-agent Nix module and transfer fixtures,
Podman Compose integration, flake manifest/registry checks, nixbot, and
representative physical plus Incus host evaluations. Finish with a source scan
for active references to retired tools and a file-level parity comparison
against `abird/master`.
