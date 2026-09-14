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
