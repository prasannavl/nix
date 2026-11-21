# Repository integration under lib

## Layout

- Repository composition: `nix/` → `lib/`.
- Repository overlays: `overlays/` → `lib/overlays/`; published overlay APIs
  stay unchanged. Reusable component ownership remains `ab/`.
- Updated root/child/host imports, updater discovery and fixtures, generated
  hardware-module imports, installer defaults and active documentation.
- Historical plans and receipts retain their original paths; the old mixed
  `lib/` implementation is not restored. Other root directories stay put.
- Both repositories were pushed/synchronized before this change. This
  repository's published base is `81cbadde81ebc2921aff65f9bbe2b95afb89ebea`.
  Layout publication is explicitly deferred for review.

## Verification

- 46 focused checks built successfully; 166 changed/moved Nix files passed
  parsing, Alejandra, Statix and strict Deadnix. Changed shell and Markdown
  files passed their configured static/format gates.
- Root input/package/app/check/shell/host/module/image names unchanged. Flake
  inputs, dependency locks, manifest, configuration/data, source pins and
  patches preserved; only flake wiring paths changed.
- 1676 relative Nix path targets preserved by an independent old/new audit.
  Shared `ab/`: 573 files, six links, exact bytes/types/full modes/link targets.
- Source-layout, updater/ref-discovery, Pi updater and Rust mirror tests passed.
  Canonical host-manager formatting, lint and full test targets passed with
  bounded compiler/test concurrency.
- `pvl-l5` toplevel drvPath evaluated successfully, sequentially with the other
  repository's one representative host; state version remains `25.11`.
- Two existing test assumptions corrected: the shared layout guard no longer
  forbids Nix's optional repository-owned patched-Cargo scenario; Nix's Markdown
  harness sources its locally generated fixture, not a repository test path.

Full check names and candidate identities:
[receipt](repository-lib-layout-2026-11.json). No fleet operation, whole-system
build, deployment or VM qualification. These focused results are not
full-repository acceptance. Host evaluations used the staged candidate, not a
clean-commit revision identity.
