# Abird tail audit (2026-11-16)

- User requested a further forward check: list every Abird commit since the last
  port, analyze commit by commit, group into logical units, port shareable units
  byte-for-byte where the destination has not diverged, then audit parity.
- Boundary: Abird `master` `d968b3885`, window `c735a7247..d968b3885` — 9 linear
  commits, no merges. Destination `master` `0dabd48b8`. `c735a7247` is the
  source tip of the follow-up port recorded in event 0028.
- Result: nothing to port. Three commits are Abird backup/secrets/plan state
  with no destination counterpart; five are already adopted (destination bytes
  identical or the destination was the origin); one documentation commit was
  partially adopted.
- Adopted unit: `.agents/docs/lang-patterns/nix.md` — the reworded `path:`
  bullet plus the repo-neutral rules the shared guidance file had drifted on.
  Kept destination-only: the "parenthesize function applications" rule; omitted
  Abird's `overlays/rust-policy.nix` Design-L paragraph (policy absent here).
  `external-source-units.md` and the `pkgs/README.md` GCP bullet were already
  byte-equal.
- Parity snapshot (`lib/`, `pkgs/`, `overlays/`, `scripts/`, `.githooks/`,
  `tf/`): 1119/1185 common paths equal, 59 destination-only, 544 Abird-only, 38
  shared files differing, no mode-only difference. Every difference is local
  policy, child-flake workspace policy, identity area, the retained patched
  Cargo lane, infrastructure state or Abird product.
- Pre-window findings, all previously recorded and retained: Abird retired the
  patched Cargo lane in `230f38141` (ledger row N222 skip); identity test copies
  under `lib/flake/tests/{pvl,abird}` diverge by design (row P043); Abird has
  not adopted this side's `40dac5f5f..0dabd48b8` tail, which exists only on its
  `pvl/master` remote ref.
- Unrequested observations: `overlays/sway.nix` and `overlays/unstable-sys.nix`
  exist with their imports commented out; `pkgs/tools/codex-wrapper/` is the
  only destination-only package tree.
- Gates: `nix fmt` clean; `nix run .#lint -- --diff --base HEAD` pass
  (documentation-only change). No whole-system or image build, fleet lint,
  deployment, live probe, secret read or history rewrite.
- Receipt:
  `.agents/docs/notes/tooling/abird-port-2026-11-followup/tail-audit-2026-11-16.md`.
