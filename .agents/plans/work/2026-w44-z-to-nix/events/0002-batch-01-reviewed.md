# Batch 01 reviewed

- Base `e74e990c`; 25 frozen source commits (global rows 84–108), one merge, 247
  first-parent path events. Exhaustive ledger: `z-to-nix-2026-10/batch-01.md`
  and `batch-01-paths.tsv` in tooling notes.
- Pi updater hardening and explicit MCP option carry forward reviewed z
  adaptations; retain nix catalog and both Pvl callers' MCP-off policy.
- Kanidm metadata regression retains non-EOL advisories. OpenDesign change is a
  host-neutral comment only; root inputs, pins and product membership stay
  local. Cross-sync playbook retains ownership/review boundaries.
- Excalidash generic helper/constructor ported without host deployment. Eight
  synthetic regressions cover container-root migration, no network, failure
  propagation, private/idempotent env creation and empty/randomness failures.
  New fail-closed hardening is a later carry-back obligation, not byte parity.
- Twelve focused checks pass; 16 Pi and 85 updater-helper native regressions
  pass. Negative controls reject the old Pi updater and three unsafe helper
  cases. Real pinned Pi prefetch/build, forced semantic-equality update and
  byte-identical no-op pass; valid output reuse is not fresh compilation.
- Pvl policy fields match exactly. Raw Pi Web units differ only through
  configurationRevision in nixos-version/system PATH. With only that revision
  aligned in an evaluation counterfactual, complete units/packages match. No
  production override or raw-unit byte-equality claim.
- All-system no-build evaluation passes without IFD after ordinary derivation
  instantiation: 76 packages / 173 checks. Package-owned Nix lint passes. No
  ARM/Darwin execution, whole-system build or live acceptance claimed.
- Final canonical/owned-path gate precedes eight signed logical commits.
  Preserve the exact candidate tree and verify signatures before advancing. The
  shared MCP API and Pvl caller commits are one integration unit.
- Next worktree starts at this branch's verified signed tip; retain this
  worktree clean. Neither master, unrelated worktree, ignored override or
  untracked z note changes. No push, activation or global compatibility audit.
