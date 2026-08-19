# Abird Post-D7A Port, 2026-08

## Scope

- Pvl primary worktree baseline: `4421afe4` on `master`, plus the uncommitted
  completed `4ecab445..d7a763f0` port.
- Previous audited Abird source tip: `d7a763f0`.
- Refreshed Abird source tip: `b37e3919`.
- Audit window: `d7a763f0..b37e3919`, six commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Three parallel read-only reviews inspected every commit before applicable units
were applied directly to the primary worktree. No side worktree, commit, push,
or live deployment was used. No secret key content was read.

## Per-commit ledger

|  # | Commit     | Subject                                   | Disposition                                                                                                                                                                                                                                          |
| -: | ---------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `4fecc668` | `fix(nixbot): converge managed restarts`  | Already adopted: the preceding cross-repository convergence follow-up produced byte-identical shared code and tests before Abird committed the same unit. Pvl retains its repository-owned deploy-note location.                                     |
|  2 | `081ffb64` | `fix(podman): preserve backend contracts` | Cleanly ported: all seven shared implementation and test paths are byte-identical. Quadlet hooks retain the declared host PATH, and implicit native container identity matches Compose project/service naming.                                       |
|  3 | `661f9f96` | `fix(zulip): raise memory ceiling`        | Skipped: it changes only Abird's `gap3-gondor` stack limit. Pvl has no matching stack-limit module, Gap3/Gondor host, or enabled analogous Zulip resource contract.                                                                                  |
|  4 | `5d88c899` | `feat(podman): default to Quadlet`        | Adopted with host adaptation: both shared hunks are byte-identical; the absent Gap3 selector removal was skipped. Pvl's three populated stacks are explicitly pinned to Compose until their unsupported service shapes receive a separate migration. |
|  5 | `2ad0403f` | `docs(podman): record fleet rollout`      | Partially adopted: the shared backend decision note is byte-identical for default selection, hook PATH, and container identity. Abird fleet handoff, plans, live rollout, publication decisions, counts, and event provenance were skipped.          |
|  6 | `b37e3919` | `style: fix Markdown formatting`          | Skipped: it only reformats Abird-owned handoff, plan, and event files excluded with the preceding documentation commit.                                                                                                                              |

## Logical port units

1. Managed-restart convergence was already present before this source window was
   published. It remains exact in `composectl.sh` and its Python tests.
2. Backend-neutral lifecycle compatibility passes the declared Compose host PATH
   to Quadlet hooks and preserves Compose's implicit `<project>_<service>_1`
   container identity, including `COMPOSE_PROJECT_NAME` precedence and
   normalized working-directory fallback.
3. The generic module now defaults new stacks to Quadlet while retaining
   explicit Compose compatibility. Pvl's populated `pvl-x2`, `pvl-a1`, and
   `pvl-l5` stacks remain Compose because Beszel uses unsupported
   `network_mode`, Nginx uses signal reload, and NVIDIA Ollama uses unsupported
   `deploy` configuration. The empty Vlab stacks inherit the new Quadlet default
   without changing runtime services.

## Parity contract

At source tip `b37e3919`, 355 of 372 common tracked working-tree paths under
`lib/**` and `pkgs/**` are byte-identical, with no Git mode differences. All
nine common paths changed by this source window are exact:

- `lib/podman-compose/composectl.sh`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/quadlet-compiler.py`
- `lib/podman-compose/quadlet-helper.sh`
- `lib/podman-compose/tests/module.nix`
- `lib/podman-compose/tests/quadlet-conversion.nix`
- `lib/podman-compose/tests/quadlet-provider-transition.nix`
- `lib/podman-compose/tests/test_composectl.py`
- `lib/podman-compose/tests/test_quadlet_runtime.py`

The tenth shared-library source path, `lib/stacks/limits/gap3-gondor.nix`, is
absent in Pvl and has no consumer. The remaining 17 byte differences are the
established repository-owned flake/catalog, hardware, image, installer, kernel,
locale, Nix, stack, sudo, systemd, package-documentation, Cloudflare
example-documentation, and NATS inventory surfaces:

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

- Bash syntax, ShellCheck, Ruff lint, direct Quadlet helper tests, and
  `git diff --check` passed.
- All six focused Podman checks passed with import from derivation disabled:
  helper, module, conversion, generator lifecycle, provider transition, and
  systemd user lifecycle.
- Backend-map evaluation proves all 18 populated Pvl instances remain Compose:
  12 on `pvl-x2` and three each on `pvl-a1` and `pvl-l5`. The empty Vlab stacks
  inherit Quadlet.
- The `pvl-x2`, `pvl-a1`, and `pvl-l5` system closures built successfully with
  import from derivation disabled.
- The complete root flake check evaluated successfully with `--no-build` and
  import from derivation disabled, including all seven NixOS configurations.
- The three Pvl compatibility overrides pass Alejandra formatting checks.
