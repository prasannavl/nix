# Event 0030 — Abird tail port (`d968b3885..f20876d35`)

- User asked for another commit-by-commit forward check of the Abird tail since
  the last port, grouping into logical units, porting shareable units
  byte-for-byte where the destination has not diverged, and a final parity
  audit.
- Boundary: Abird `master` `f20876d35`, window `d968b3885..f20876d35` — 9 linear
  commits, no merges. `d968b3885` is event 0029's audited tip. Destination base
  `6327ad721`.
- Result: two shared code units and two documentation units ported; three
  commits already adopted; three skipped with reasons; one commit partially
  adopted.
- Ported: excalidash bundled-Prisma migration (`helper.sh` + regression test
  from `0e2248687`); activation-failure diagnostics (`health_runtime.rs`,
  `host_runtime.rs`, `native.rs`, `tests/fleet_host_runtime.rs` from
  `9b22b2966`); the note-appended activation section; the output-renderer
  contract note tail from `5cbd32f69`/`0a842df24`.
- Already adopted: `9ae40df84` (38/39 paths byte-equal), `b3a438947`,
  `f20876d35`, plus the rest of `5cbd32f69`/`0a842df24`.
- Skipped: `c9a586cc5` (Abird plan state) and `1bd57ef55` (26 host-local pins
  for `hosts/abird-*`/`hosts/gap3-*`; destination equivalents already at or
  above the refreshed versions). `0e2248687`'s host file and host note have no
  counterpart.
- Parity snapshot: `lib/` 548/563, `pkgs/` 492/509, `overlays/` 2/5, `scripts/`
  27/31, `tf/` 56/84 — 1125/1192 common paths equal, no mode-only difference.
  Remaining differences are identity/host policy, the retained patched Cargo
  lane, child-flake signatures, destination-ahead pins and unshipped Abird
  products.
- Gates: `nix fmt` clean, `nix run .#lint -- --diff --base HEAD` exit 0,
  excalidash helper suite 9/9, `cargo test -p abird-host-manager` green. One
  pre-existing flaky test (`descriptor_transfer_preserves_original_exclusion`)
  reproduced on unmodified upstream bytes; not caused by the port.
- No whole-system build, fleet operation, deployment, live probe, secret read or
  history rewrite. Receipt:
  `.agents/docs/notes/tooling/abird-port-2026-11-followup/tail-port-2026-11-17.md`.
