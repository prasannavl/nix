# Abird Nix-native projection port

## Boundary

- Source: `/home/pvl/spaces/abird/src/z`.
- Frozen source range: `690807d8..5204195a`.
- Target base: Pvl `fb57057639cc6a03bc032bdc7c17441c96f289f2`.
- Landing mode: staged directly in the Pvl `master` worktree for human review;
  no commit, push, deployment, or live mutation.

The audit followed the source commits in order, then grouped the accepted work
into shared projection composition, host admission, host-manager publication and
runtime reconciliation, Nixbot compatibility, repository composition, and
documentation. Abird topology, products, historical work capsules, and secret
composition stayed source-owned.

## Source-order dispositions

| Commit     | Source intent                                       | Pvl disposition                                                                                                                |
| ---------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `06b05f18` | Add Nix-native projection architecture              | Port shared Nix, Rust, Bash, tests, validation helpers, and account API; adapt only the Pvl repository manifest and consumers. |
| `939119c4` | Merge projection workstreams                        | Merge metadata and Abird coordination records excluded; their implementation is represented by the surrounding commits.        |
| `379fb331` | Admit schema rollout                                | Port generic projection/admission fixes and tests; exclude Abird family declarations and identity fixtures.                    |
| `8a15aad2` | Compose Abird secret scopes                         | Exclude Abird secret/topology changes; adapt Pvl recipients to shared accounts and retain the generic repository model.        |
| `af3c6e72` | Localize Zulip service module                       | Exclude; Zulip and the affected Abird host topology do not exist in Pvl.                                                       |
| `1b3b968e` | Format projection documentation                     | Carry formatting through the accepted shared design documents; exclude plan-event history.                                     |
| `cb910ac6` | Retire legacy service-move paths                    | Port shared Nix, host-agent, host-manager, and tests; exclude Abird declarations, runtime receipts, and archived journals.     |
| `0f14b1b5` | Record Abird projection-retirement plan             | Exclude; source workstream history is not a Pvl runtime or design dependency.                                                  |
| `5204195a` | Make generation-admission output concise by default | Port the shared host-agent, manager, Nixbot, tests, and design contract exactly.                                               |

## Pvl composition

`config/default.nix` now owns one prebuilt `pvl` configuration family under
`config/pvl`, containing the `pvl` and `pvl-dev` stacks. It also owns shared
accounts, cache trust, the repository module registry, and
`defaultScope =
"pvl"`. Hosts continue to select `stacks.pvl` explicitly.
Stack-independent images and installers receive shared accounts.
Repository-authored stack files no longer live under `lib/`, and the
nondeployable `stacks.all` compatibility object is gone.

Secret recipient composition consumes `repositoryConfig.shared.accounts.users`
from the same manifest. This replaces its stale import of the removed
`lib/stacks.all.users` compatibility path. The Pvl repository check now forces
the complete recipient map and requires every secret to have a non-empty list of
public keys.

The Pvl deployment inventory remains a plain attribute set. The shared root can
also consume a repository inventory function receiving canonical stacks. Pvl
does not author placement or move fragments in this port, so both built-in
projection domains evaluate their neutral contracts and runtime plan count is
zero.

Pvl preserves its repository-specific flake checks, host inventory, stack
registry, Nixbot identity test, package manifest, NVIDIA and application pins,
and physical fabric projection. The generic configuration-family test uses Pvl's
`config/` manifest directory as its reserved-`default.nix` fixture instead of
the Abird-only `config/abird` directory.

## Parity inventory

The final filesystem comparison covers tracked common paths under `lib/**`,
`pkgs/**`, and `scripts/**` and compares SHA-256 content plus executable mode.
There are 570 common paths: 552 exact, 18 explained content differences, and no
mode differences. The complete common trees for `lib/services/**`,
`lib/incus/**`, `lib/validation/**`, `pkgs/tools/abird-host-agent/**`,
`pkgs/tools/abird-host-manager/**`, and `pkgs/tools/nixbot/**` are byte- and
mode-identical. Neither repository has tracked files under
`lib/systemd-user-manager/**`.

The 18 differences are Pvl-owned external-source pins and update policy, Pvl
hardware/locale/network/sudo/systemd policy, package documentation and manifest,
`lib/flake/repo-checks.nix`, and the repository-neutral Pvl fixture path in
`lib/flake/tests/configuration-family.nix`. No changed generic source path is
unaccounted for.

## Validation

- `nix eval --json .#hostManager.defaultSelection` returned
  `{ "scope": "pvl", "stack": "pvl" }`.
- `hostManager.stacks` and `hostManager.scopes` contain exactly `pvl` and
  `pvl-dev`; the projection snapshot has move schema 2, placement schema 3, and
  zero runtime plans.
- The `pvl` and `pvl-dev` service-registry data and account records are
  JSON-equivalent to the committed pre-port flake outputs.
- The complete secret-recipient map is JSON-equivalent to the committed pre-port
  evaluation after replacing the removed `stacks.all` lookup.
- All seven Pvl NixOS configurations evaluate.
- `nix flake check --no-build --print-build-logs` passed.
- Focused projection, repository-composition, host-agent, and host-manager Nix
  checks build successfully.
- The Nixbot helper suite passed all 287 tests.
- The host-agent suite passed all 160 tests serially; the complete host-manager
  library, binary, and integration suites also passed serially.
- `cargo fmt --check`, `git diff --cached --check`, and the repository's
  authoritative no-IFD `.#lint` application passed.

## First deployment correction

The first Pvl deployment attempt was rejected before host mutation. Both
`pvl-a1` and `pvl-l5` still ran complete pre-registry authority with a schema-1
service-placement document, while the initially ported adapter accepted only
schema 3. The incoming dispatcher therefore could not prove automatic rollback
to the unregistered predecessor.

The failed deployment left both hosts on their prior generations. Read-only
inspection also found the same schema-1, empty-move contract on `pvl-x2` and
`pvl-vlab`; the remaining inventory endpoints were not reachable from the
operator environment during the audit. Runtime agent state is not the source of
the rejected schema and must not be deleted to perform this rollout.

Pvl instead uses an authority-first staging generation. The temporary
`config/pvl/projection-authority-staging.nix` module keeps the generated
schema-3 placement, desired-state, and resource authority while publishing an
empty generation-admission registry. This deploys the new authority without
invoking the service-move adapter. The shared host-agent implementation and
tests remain byte-identical to Abird and continue to accept only schema 3.

After every deployable Pvl host has successfully entered the staging generation,
remove the temporary module and its registration from `config/default.nix`. The
following deployment registers `serviceMoves`; its predecessor then already has
complete schema-3 authority, so the strict adapter can prove both forward
admission and automatic rollback without a legacy normalizer or state deletion.
