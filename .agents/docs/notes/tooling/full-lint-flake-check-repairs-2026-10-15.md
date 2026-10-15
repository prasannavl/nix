# Full lint flake-check repairs, 2026-10-15

## Scope

`lint --full` on Pvl `master` `d359eae7` exited non-zero at `root-flake-check`
(`nix flake check --all-systems`). Auto/diff lint and CI
(`.github/workflows/pr-lint.yaml` runs `--diff`, which evaluates only root
output indexes and changed hosts, never `.#checks`) never reach the full check,
so the three failures below accumulated unnoticed. All three are fixed and
`nix run .#lint -- --full` now exits 0 with 161/161 cross-system checks
evaluating.

## Failures and root causes

1. `pvl-child-flake-parity` (x86_64-linux) — regression from `9c133889`
   (`feat(rust): add closure cache composition`). That commit added the
   `libExports` output to `mkFlakeOutputs` and merged it with
   `nixpkgs.lib.optionalAttrs`. `optionalAttrs` forces `nixpkgs.lib` even when
   no library is exported, which evaluates the `nixpkgs` input. The parity test
   injects
   `injectedArgs.nixpkgs = throw "injected package set must not
   evaluate nixpkgs"`
   to prove a complete `pkgsForSystem` injection needs no `nixpkgs`; the new
   merge broke that contract. Fix: replace the `optionalAttrs` merge with a
   plain `builtins`-level conditional in `lib/flake/stack/package.nix`, so
   `nixpkgs` stays untouched when `libExports` returns `{}`. Exported-library
   behavior is unchanged.

2. `lib-kanidm-normalization` (x86_64-linux) — the committed `flake.lock`
   nixpkgs (`f45c6f04`, 2026-09-28, introduced by `7cab6898`) marks
   `kanidm_1_10` `unsupported = true`, so its `meta.knownVulnerabilities`
   carries the 1.10 end-of-life notice. The check evaluates
   `pkgs/ext/kanidm-server/cli.nix`, which deliberately pins the CLI to the same
   1.10.4 release as the server image (`sources.nix`); the EOL notice made
   `(app {}).drvPath` throw. Fix: in the repo-owned CLI wrapper, filter only the
   `has reached end-of-life` entry out of `knownVulnerabilities`; any real known
   vulnerability still blocks evaluation. This is a repo-local, scoped
   acknowledgement of the deliberate server/CLI compatibility pin, not a general
   insecure-package waiver.

3. `lib-prism-llama-cpp-package` (aarch64-linux) — the package declares
   `platforms = ["x86_64-linux"]`, but the shared `lib/tests/default.nix`
   registers its contract check on every Linux system. `--all-systems` therefore
   evaluated the x86_64-only package on aarch64-linux and threw "not available
   on the requested hostPlatform". Fix: gate the check behind
   `pkgs.stdenv.hostPlatform.isx86_64`, matching the existing `isLinux` gate.

## Shared-file / Abird coordination

- `lib/flake/stack/package.nix` and `lib/tests/default.nix` are shared files.
  The `libExports` merge fix and the platform gate are both generic and should
  be ported to Abird the next time shared bytes are synced: the `optionalAttrs`
  bug exists wherever `9c133889`'s `libExports` landed, and the prism gate is
  platform-correctness that does not depend on the nixpkgs lock.
- `pkgs/ext/kanidm-server/cli.nix` is the repo-owned CLI wrapper. Abird should
  confirm whether its pin needs the same EOL filter; its nixpkgs lock may not
  yet carry the `kanidm_1_10` EOL marker.

## Validation

- `nix eval .#checks.<system>.<name>.drvPath` over all 161 checks
  (aarch64-linux + x86_64-linux): 161/161 evaluate. Before the fixes,
  `pvl-child-flake-parity`, `lib-kanidm-normalization`, and
  `aarch64-linux.lib-prism-llama-cpp-package` failed.
- `nix run .#lint -- --full` exits 0 (alejandra, deno, tofu, shfmt, statix,
  deadnix, shellcheck, actionlint, markdownlint, tflint, root flake check, and
  every sub-project fmt/lint/test check).
- `nix run .#fmt` clean; `git diff` limited to the three files above.
