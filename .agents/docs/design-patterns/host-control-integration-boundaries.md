# Host Control Integration Boundaries

## Landed Interfaces

Native `abird-host-manager fleet` and Bash Nixbot are both present. Bash remains
the active Nixbot entrypoint. The Nix-native projection fold, typed projection
snapshot, publication transaction, generation-admission registry, and succinct
pre-switch output contract are part of the shared host-control implementation.
Pvl currently authors no service placement or move fragments, so both built-in
domains evaluate to their neutral contracts.

## Repository Composition

`config/default.nix` is Pvl's repository manifest. It wraps the existing `pvl`
and `pvl-dev` stacks in one prebuilt `pvl` configuration family, selects `pvl`
as the default operator scope, owns cache trust and module registration, and
publishes repository-wide accounts as `repository.shared.accounts`.

Deployable hosts still choose their stack explicitly. Stack-independent images
and installers receive shared accounts without a synthetic default or aggregate
stack. `hosts/nixbot.nix` remains Pvl-owned deployment inventory and may stay a
plain attribute set; the shared root also supports a function receiving the
canonical stack set.

Generic `lib/flake` helpers accept caller-owned repository configuration and
inventory. Concrete stacks, hosts, fabric prefixes, service placement, and
physical enforcement stay repository-owned. Pvl's physical fabric projection
must remain independent of Abird imports. Share pure helpers and synthetic tests
without importing Abird product packages or topology fixtures.

## Desired State And Ownership

Nix owns authored placement, moves, leases, repository paths, and derived
runtime identity. Rust consumes the evaluated typed snapshot; journals retain
observed receipts, retries, and private capabilities. JSON is an ephemeral
evaluation transport or a runtime-only projection format, never a second
service-move authoring store. Do not parse arbitrary Nix source in Rust.

Intent domains produce generation and runtime views through the generic fold.
Adapters declare validated fragments, dependencies, claims, owned paths, and
optional admission/runtime capabilities. They are additive and cannot replace
built-ins or acquire a second declaration channel. Future identity, ingress, or
workspace work should use this domain boundary.

## Publication And Runtime Authority

Preserve the manager's single publication transaction: expected clean revision,
exact preimages, evaluated owned paths, canonical documents, exact staging,
write-evaluate-compare validation, postimages, and commit/publication retention.
Foreign index state, unexpected repository revisions, ambiguous lineage, and
unexpected path drift fail closed. Repository mutation paths come from the
evaluated contract rather than a Rust copy of the Nix layout convention.

Publication has repository-wide writer exclusion and a deployment-spanning
lease. It does not hold the runtime journal lock across deployment. Runtime
reconciliation is an ordered, resumable saga with truthful per-item evidence.
Adoption deployment, cleanup deployment, and recovery release remain distinct
steps; see `nix-native-service-moves.md`. Required affected-host coverage must
reach both subprocess and in-process fleet adapters. A resource deferral is not
terminal success.

## Admission And Compatibility

Nixbot delegates to a usable current-generation admission dispatcher when
present. Broken registered authority, partial interfaces, and retained contracts
without validators fail closed. First registration proves both the forward and
rollback transition against complete predecessor authority. Domain retirement
retains a neutral tombstone rather than discarding rollback authority.

Keep admission rejection separate from SSH recovery and queued rollback.
Automated callers use quiet preflight mode, capture the structured result, and
replay it only on failure; direct operators get concise human output unless they
request `--json`. Preserve flags, environment variables, CI, dirty-staged and
exact-revision behavior, cancellation, diagnostics, and cleanup across any
future engine cutover. Nix subprocesses must evaluate the intended checkout
without inherited Git selectors redirecting them to another repository.

Builder leases stay controller-owned and generation-independent, locking the
stable `/nix/var/nix` inode through the inline protocol. Authenticated
`ssh-ng://` builder-store result import remains separate from signed-cache
deployment distribution.

## Shared Seam Changes

Freeze source and target revisions and identify one integrator before parallel
edits to a shared seam. Exchange behavioral requirements and work against landed
interfaces or an explicitly reviewed adapter. Do not replace newer
repository-owned behavior with a whole file from another topology. Re-run
focused seam checks and exact byte/mode comparisons after reconciliation.
