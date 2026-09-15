# Host Control Integration Boundaries

## Landed And Proposed Interfaces

Native `abird-host-manager fleet` and Bash Nixbot are present. Bash remains the
active Nixbot engine. Upstream projection hardening and a Rust compatibility
cutover are separate pending work; their plans do not establish landed APIs in
Pvl. Check the actual checkout before changing a shared seam.

## Desired State And Ownership

Nix owns authored placement, moves, and derived runtime identity. Rust consumes
an evaluated contract; journals retain observed receipts, retries, and private
capabilities. Ephemeral JSON is transport, while existing JSON transactions
remain compatibility evidence. Do not parse arbitrary Nix source in Rust.

Generic `lib/flake` helpers accept caller-owned profiles and registries.
Concrete stacks, hosts, fabric prefixes, service placement, and physical
enforcement stay repository-owned. Pvl's physical fabric projection must remain
independent of Abird imports. Share pure helpers and synthetic tests without
importing Abird product packages or topology fixtures.

## Publication And Runtime Authority

Preserve the manager's publication pipeline, expected revisions, exact
preimages, owned paths, writer exclusion, and deployment-spanning publication
lease. Foreign index state and unexpected repository revisions must fail closed.
Do not hold the runtime journal lock across deployment.

Runtime reconciliation is resumable and must retain truthful evidence. Adoption
deployment, cleanup deployment, and recovery release remain distinct steps; see
`nix-native-service-moves.md`. Required affected-host coverage must reach both
subprocess and in-process fleet adapters. A resource deferral is not terminal
success.

## Admission And Compatibility

Nixbot delegates to a usable current-generation admission dispatcher when
present. Broken registered authority and retained contracts without their
validators fail closed. Ordinary-host rollback requires absence of retained
authority. A first normal deployment may introduce an incoming interface, but
incoming evidence never supplies rollback authority.

Keep admission rejection separate from SSH recovery and queued rollback.
Preserve flags, environment variables, CI, dirty-staged and exact-revision
behavior, cancellation, diagnostics, and cleanup across any future engine
cutover. Nix subprocesses must evaluate the intended checkout without inherited
Git selectors redirecting them to another repository.

Builder leases stay controller-owned and generation-independent, locking the
stable `/nix/var/nix` inode through the inline protocol. Authenticated
`ssh-ng://` builder-store result import remains separate from signed-cache
deployment distribution.

## Shared Seam Changes

Freeze source and target revisions and identify one integrator before parallel
edits to a shared seam. Exchange behavioral requirements and work against landed
interfaces or an explicitly reviewed adapter. Do not replace newer main behavior
with a whole file from an older worktree. Re-run focused seam checks and update
the source commit dispositions after reconciliation.
