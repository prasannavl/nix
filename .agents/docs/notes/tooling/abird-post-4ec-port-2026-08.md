# Abird Post-4EC Port, 2026-08

## Scope

- Pvl pre-port baseline: `4421afe4` on primary `master`.
- Previous completed Abird audit tip: `4ecab445`.
- Refreshed Abird source tip: `d7a763f0`.
- Audit window: `4ecab445..d7a763f0`, four commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Three parallel read-only reviews inspected every commit before the shared units
were applied directly to the primary worktree. No commit or push was performed
by this audit. No secret key content was read.

## Per-commit ledger

|  # | Commit     | Subject                                   | Disposition                                                                                                                                                                   |
| -: | ---------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `d1b76650` | `fix(podman): harden Quadlet transitions` | Cleanly ported: the complete shared implementation, tests, and reusable backend note are exact.                                                                               |
|  2 | `1d697240` | `feat(gap3): migrate services to Quadlet` | Skipped: the Gap3 backend selector and Garage bootstrap are absent host-owned topology with no Pvl consumer.                                                                  |
|  3 | `de8803c4` | `feat(nixbot): restart managed services`  | Adopted, then aligned: shared code/tests were ported; the initial Pvl-only state filter was superseded by byte-identical bounded transition convergence in both repositories. |
|  4 | `d7a763f0` | `docs(podman): record Gap3 rollout`       | Skipped: Abird-only live canary, recovery, rollout, plan, and event provenance.                                                                                               |

## Logical port units

1. Quadlet transition hardening: retain the immutable Compose stop helper for a
   previous-generation provider, stage native inputs from build materialization,
   and identify persistent native runtime units by systemd `SourcePath`.
2. Backend-neutral managed restart: expose explicit Nixbot CLI, environment,
   completion, and CI-forwarding contracts; bypass only generation-match
   skipping; restart applicable public service facades once per owning user
   after activation and before health verification. Manual services settle
   current systemd jobs and transitional states within one bounded per-user
   deadline; terminal failed services restart, terminal active services use a
   conditional restart and are re-observed before and after the unconditional
   recovery batch, terminal inactive services remain stopped, and incomplete,
   unknown, stuck, or finally failed states fail closed. A manual service that
   becomes failed around the conditional operation joins the unconditional
   recovery batch.

The Gap3 Quadlet selector, Garage service bootstrap, live recovery history,
migration plans, and workstream events remain excluded because Pvl has no
`gap3-rivendell` service module or corresponding Garage consumer.

## Parity contract

After the shared convergence follow-up, 353 of 372 common working-tree paths
under `lib/**` and `pkgs/**` are byte-identical, with no Git mode differences.
Six of the eight common paths changed by this source window are exact, including
the two managed-restart paths aligned by the follow-up:

- `lib/podman-compose/composectl.sh`
- `lib/podman-compose/tests/quadlet-provider-transition.nix`
- `lib/podman-compose/tests/test_composectl.py`
- `pkgs/tools/nixbot/nixbot.bash`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

Two source-window paths now differ because Abird has a separate, uncommitted
Quadlet-default workstream in progress. They are outside this restart-managed
convergence follow-up and were preserved untouched:

- `lib/podman-compose/default.nix`
- `lib/podman-compose/tests/module.nix`

The other 17 differences predate this follow-up and are repository-owned
flake/catalog, hardware, image, installer, kernel, locale, Nix, stack, sudo,
systemd, package-documentation, Cloudflare example-documentation, and NATS
inventory surfaces:

- `lib/flake/default.nix`
- `lib/flake/root.nix`
- `lib/flake/tests/default.nix`
- `lib/hardware.nix`
- `lib/images/default.nix`
- `lib/installer/config/default.nix`
- `lib/kernel.nix`
- `lib/locale.nix`
- `lib/nix.nix`
- `lib/stacks/default.nix`
- `lib/sudo.nix`
- `lib/systemd.nix`
- `pkgs/README.md`
- `pkgs/cloudflare-apps/README.md`
- `pkgs/cloudflare-apps/llmug-hello/README.md`
- `pkgs/manifest.nix`
- `pkgs/support/nats-streams/default.nix`

## Validation

- Shared shell syntax, ShellCheck, Python source compilation, Ruff formatting,
  and Ruff lint passed.
- Shared managed-restart tests passed in both repositories, including
  stable-state selection, transitional settlement, masked-inactive preservation,
  conditional-race recovery, final-state rejection, incomplete or unknown state
  rejection, and bounded timeout failure.
- Focused Podman helper, module, conversion, provider-transition, and user
  lifecycle checks passed with import-from-derivation disabled.
- The Nixbot helper test suite passed with the new option, forwarding, ordering,
  and activation assertions.
- Full diff lint and affected host evaluations passed.
- Direct `nixbot.checks.lint` evaluation fails identically in Pvl and Abird on
  the pre-existing `SC2174` warning at `prepare_host_local_lock_path`; the
  audited window does not touch that line, so the shared script remains exact.
- Final source refetch left `abird/master` unchanged at `d7a763f0`.
