# Host-agent first installation

## Source and representation

- Nix declarations/projections remain desired-state authority. Generated JSON is
  the immutable runtime encoding read by shell/Rust; no second authoring
  surface.
- Current-generation documents protect established placement, holds and
  rollback. Registry absence alone is not evidence that ownership never existed.

## Repair

- Shared `admission-tools.nix` constructs production/test helpers from the same
  implementation and explicit filesystem roots. No host-name exception, runtime
  force flag, synthetic predecessor contract or new persistent receipt.
- Existing agent-free OS: no configuration, binary, helper or unit footprint.
  Check live configuration plus configured/default state, backup and runtime
  roots. Accept only empty scaffolding and an empty, singly linked `state.lock`;
  reject links, special files and all other retained artifacts without reading
  or deleting them. The agent's typed filesystem check distinguishes missing
  paths from permission/I/O errors and unavailable ancestors; shell dispatch
  does not infer absence from a failed `test -e`. Configured roots are canonical
  absolute paths.
- Nix-derived declaration facts reject enrollment/retirement with declared holds
  or desired resource transitions, including an empty domain registry.
- Domain adapters must prove the reverse edge before first installation.
  Nullable digests encode absent documents. The service-move adapter admits
  retirement only from neutral authority: no moves, desired states or declared
  holds. The real agent validates the existing neutral documents read-only.
- Existing-OS enrollment and agent-free rollback accept
  switch/test/dry-activate, not boot-only scheduling: today's proof cannot bind
  state at a later reboot.
- Actual rollback repeats state and adapter proofs. New holds, jobs, receipts,
  backups or unknown state close the retirement edge. No general domain-removal
  exception; registered/partial authority still fails closed when incomplete.
- Current dispatcher remains authoritative. Native manager selection,
  acquisition deferral and rejected-before-switch handling are unchanged.
  Partial activation without a usable current dispatcher retains existing
  fail-closed recovery; this repair is not a guarantee that every interrupted
  switch can roll back.

## Verification

- Both repositories: fresh sandbox agent tests (162 cases each), Clippy, module
  and generation-boundary checks passed. Manager sandbox suites also rebuilt;
  adjacent manager/Nixbot module outputs reused.
- Canonical formatting/lint and all-system, no-build/no-IFD evaluation passed.
  Evaluation is not a full cross-platform build.

- `lib-abird-host-agent-generation`: real dispatcher, adapter and agent;
  existing OS enrollment and reverse admission for switch/test/dry-activate; no
  state creation; real empty hold-store initialization and retry; partial/broken
  authority, inaccessible/dangling ancestors, special files, retained state,
  unknown records, lock aliases, non-neutral projections/declarations and
  ordinary domain-removal refusals.
- Existing `lib-abird-host-agent` suite remains intact, including bootstrap and
  complete unregistered-predecessor compatibility.
- Target-specific candidate evidence and rollout status belong in the owning
  repository's operator note, not this generic implementation contract.
- Source/sandbox verification is not live deployment or operational rollback
  qualification. Do not fabricate JSON or disable admission to bypass a refusal.
