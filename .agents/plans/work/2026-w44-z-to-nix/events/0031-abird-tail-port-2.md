# Event 0031 — Abird tail port, second pass (`f20876d35..46c3b6298`)

- User asked to repeat the commit-by-commit forward port for the newer Abird
  tail, byte-for-byte where the destination has not diverged, then audit parity.
- Boundary: Abird `master` `46c3b6298`, window `f20876d35..46c3b6298` — 5 linear
  commits, no merges. Destination base `2f100c51c`.
- Result: three shared units ported, two host-local commits skipped.
- Ported: NVIDIA production/new-feature/beta branch tracking
  (`lib/ext/nvidia/{sources.nix,update.sh}` from `73b479bc3`); exact Go
  toolchain selection for Tailscale with the `go-overlay` root input, lock node
  and overlay (`7da7965d5`); go-overlay and fenix toolchain cache trust in
  `lib/nix.nix` plus the registry test counts (`46c3b6298`). All four `lib/ext`
  files are byte-identical to the source.
- Skipped: `456a86f60` (Forgejo 17.0.1) and `3b754962e` (Zulip 13.2) — both are
  Abird host files and host notes; the destination ships the shared Forgejo
  service without a host consumer and its `pvl-x2` Zulip stack is a separate,
  older host-local pin.
- Adaptation: the destination keeps its `cache.numtide.com`/`niks3.numtide.com`
  entries, so the registry asserts are 5 substituters and 6 trusted keys; the
  lock keeps its newer pins with only the `go-overlay` node added.
- Gates: `pvl-x2` and `pvl-a1` toplevel drvPaths evaluate;
  `lib-nix-repo-registry` check passes; tailscale resolves to `1.104.7` on
  `go-bin` 1.27.4; nvidia stays `595.91.07`; updater suite 153/153; `nix fmt`
  clean; diff lint exit 0. No build, fleet operation, deployment, live probe or
  history rewrite.
- Parity snapshot: `lib/` 546/561, `pkgs/` 492/509, `overlays/` 2/5, `scripts/`
  27/31, `tf/` 56/84 — 1123/1190 common paths equal; the 67 differing files are
  the same classified set as event 0030. Receipt:
  `.agents/docs/notes/tooling/abird-port-2026-11-followup/tail-port-2026-11-17b.md`.
