# Batch 09 shared unit staged

- Base: signed batch-08 checkpoint `9df47137`; masters remain nix `9aecdcdc` and
  z `8ad96801`. Batch 08 retains its sixteen-path staged tree `9ce141a1`.
- Reviewed 25 frozen commits / 177 first-parent events / 127 paths. Ledger
  records private product/evidence ownership and 21 already-present events.
- Staged coherent routing/output code, managed service/schema/caller changes,
  NUL-field handling and tests. No host/inventory/input or private product port.
- Extracted only three schema-v2 named-route fixtures from source migration
  evidence into manager-owned JSON. Both Rust and Bash consume that data; Nix
  copies only the JSON into the Bash fixture tree. No private parity ledger.
- All 307 prior generic Bash declarations and the Pvl sibling retained;
  candidate has 332 generic declarations. No legacy retirement or compatibility
  cutover.
- Initial canonical and native/package checks running. Four old-code controls
  fail against the actual base Bash script and pass against the candidate; final
  delivered-tree gates and signed logical checkpoint still pending.
- Code-bearing batch 09 is not eligible for automatic documentation-only main
  integration. Batch 08 remains unapproved too; no push, probe or deployment.
- Incus downgrade and z unstable/Tailscale holds unchanged. Global convergence
  and carry-back remain later work.
