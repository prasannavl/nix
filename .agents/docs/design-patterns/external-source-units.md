# External Source Units

## Scope

Canonical layout, discovery, reporting, and update rules for externally sourced
derivations under `lib/ext/` and `pkgs/ext/`.

## Ownership

- `lib/ext/<unit>/` owns internal overrides, overlay inputs, and maintenance
  derivations.
- `pkgs/ext/<unit>/` owns independently exported external packages registered
  through `pkgs/manifest.nix`.
- Do not collapse the two roots. Their consumer boundary is intentional; the
  source convention spans both.

## Unit convention

An external unit may contain:

```text
<unit>/
  default.nix
  sources.nix
  update.sh
```

Participation follows the files present in the unit directory:

| `sources.nix` | Executable `update.sh` | Behavior          |
| ------------- | ---------------------- | ----------------- |
| present       | present                | report and update |
| present       | absent                 | report only       |
| absent        | absent                 | ignored           |
| absent        | present                | invalid           |

The convention itself is the discovery mechanism. Do not add a central package
manifest or hard-coded report catalog.

## Source records

`sources.nix` is the canonical source index for its unit. It evaluates to an
attribute set keyed by package name, including single-package units. Each entry
contains a primary `kind`, current `version` or revision, upstream identity, and
all fixed-output or dependency hashes needed by the package.

Keep `sources.nix` as literal, evaluation-safe Nix data:

- no fetchers or derivations
- no network access or import-from-derivation
- no package build logic
- explicit resolved revisions, digests, and hashes

Attach nested records for additional artifacts such as OCI images or platform
release archives. `kind` describes the primary upstream used for reporting;
package-local updaters remain free to use the specialized mechanism required by
the unit.

`default.nix` imports its sibling `sources.nix` and owns only packaging and
runtime behavior. Version updates must not regenerate `default.nix`.

## Reporting and updates

`scripts/update.sh` discovers `sources.nix` files one directory below both
external roots.

- Units with an executable updater delegate reports and updates to that script.
- Units without an updater use the generic kind-based reporter and never mutate
  source state.
- A non-executable `update.sh` is rejected rather than silently treated as
  report-only.

Every package-local updater supports `--report`, `--force`, and `--color=WHEN`.
Suite updaters may add `--package`; single-package updaters may add `--version`.
Updaters read and replace only their sibling `sources.nix`, skip expensive
prefetch work for current versions, format generated Nix, and use a
repository-local temporary path before atomic replacement.

## Registry lookups and report failures

Standard Registry V2 image tag discovery uses an anonymous, challenge-driven
client. Request tags without credentials first; on HTTP 401 select the Bearer
challenge, validate its absolute HTTPS realm, preserve realm query parameters,
pass the advertised service and scopes, and retry tags once with the returned
`token` or `access_token`. Authentication schemes and parameter names are case
insensitive; quoted commas and repeated headers must remain intact. Docker Hub
uses its canonical endpoint alias. Quay and GitHub release discovery retain
their explicit adapters.

The shared client does not read credential stores. Unsupported authentication,
invalid realms, missing tokens, token-service failures, and failed authenticated
retries remain failed checks. Keep HTTP failures attributable to the endpoint
and operation, distinguish opening a request from reading its body, and state
the configured socket timeout. Rendered request URLs omit credentials, queries,
and fragments.

Image reporting deduplicates checks by full image reference. Its final failure
summary lists every failed reference, error, and affected stack/host/Compose/
instance context deterministically. An incomplete image report exits nonzero;
image updates stop before planning or writing pins if any check fails. This gate
covers image pins: earlier phases of the outer update command may already have
written their own dependency updates. Successful lookups and displayed update
arrows do not authorize application upgrades or database migrations.

### Inline image update holds

Structured Nix Compose sources may attach a review boundary directly to an image
declaration:

```nix
image = {
  ref = "docker.io/example/database:1.2.3";
  hold = "The next release requires a separate persisted-data migration.";
};
```

An ordinary image string remains automatically updateable. The structured form
contains exactly one current `ref` and, while held, one non-empty `hold` reason;
it does not duplicate a current version, predict a target, or require a central
policy catalog. The Podman Compose module renders only `ref` into Compose and
exposes the hold as evaluated updater metadata. Removing `hold` re-enables
automatic updates without moving the reference.

The image updater still checks and reports the newest comparable tag for a held
image, appends the reason to that occurrence, and excludes it from edit
planning. Holds are per declaration, so another service may update the same
registry reference independently. Conflicting held and automatic uses of one
owning declaration are an error rather than a policy bypass.

Use a hold when an image transition is coupled to package-owned artifacts,
compatibility work, or an explicit state migration. Remove the hold only when
that boundary has been reviewed; do not add registry-wide exceptions or hide a
pin from discovery.

The outer report command retains failures from serial and parallel package
updaters, generic source reporters, flake metadata, and image reporting. Its
final stderr footer names each failed job and exit status; a later successful
section cannot clear an earlier failure. Preserve source ownership, existing
upgrade tracks, and atomic replacement independently of registry authentication
and diagnostics.

## Validation

- Evaluate every `sources.nix` directly with `nix eval --json --file`.
- Build or evaluate affected package consumers after source extraction changes.
- Test all four discovery states, generic report kinds, lookup failures, and
  same-version no-op behavior.
- Run `scripts/update.sh --report --only-ext` and
  `scripts/update.sh --report --only-pkgs-ext` after changing discovery or
  report behavior.

## Source of truth files

- `lib/ext/*/sources.nix`
- `lib/ext/*/update.sh`
- `pkgs/ext/*/sources.nix`
- `pkgs/ext/*/update.sh`
- `scripts/update.sh`
- `scripts/support/report-ext-sources.py`
