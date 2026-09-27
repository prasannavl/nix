# Abird parity port audit after `278a2cba`, 2026-09-26

## Boundary

- Previous recorded shared boundary: `6fe3b63a` (frozen by
  [the post-`6fe3b63a` re-audit](./abird-post-6fe3b63a-reaudit-2026-09.md)).
- Configured `abird/master` tip at audit: `278a2cba` (`style: fix lint`).
- Pvl target: `master` at `0be0bf94`, clean working tree.
- Audit window: `6fe3b63a..278a2cba`, 12 linear commits.
- Landing mode: read-only verification. Every shared implementation unit in the
  window was already present in Pvl, so no port commit was authored; no push,
  deployment, service restart, image pull, database query, or migration was
  performed. Secret-key files were neither listed nor read.

## Result

Every shared implementation unit in the window is byte- and mode-identical in
Pvl. There is no unported change and no POSSIBLE GAP.

The window is almost entirely the Abird-side mirror of Pvl-authored shared work
(the `abird/codex/pvl-shared-port-20260926` and `-20260926b` series), followed
by Abird ledger/lint commits. Each Abird commit was compared at the file level
by Git blob and mode against Pvl `HEAD`; the only content differences are
Pvl-side additions and repository-owned divergences, never Abird content absent
from Pvl.

## Every source commit

Status vocabulary: **adopted** = the shared unit is already present and
byte/mode-identical in Pvl (mostly an Abird mirror of Pvl-authored work);
**skipped** = source-only docs, ledger, or identity with no Pvl unit.

|  # | Commit     | Subject                                               | Status  | Disposition                                                                                                                                                                                                                      |
| -: | ---------- | ----------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `44766d09` | `fix(nvidia): parse production branch from unix.md`   | adopted | `lib/ext/nvidia/update.sh` byte-identical; Abird mirror of Pvl `ed753ecb`. Only the Pvl-owned `lib/ext/nvidia/sources.nix` pin and the pin-divergence paragraph in the source note differ, by design.                            |
|  2 | `2bba63f9` | `chore(pi): port source pins and npm fetcher v2`      | adopted | `lib/ext/pi/pi-models-discovery/default.nix` and `pi-subagents/default.nix` byte-identical; `lib/ext/pi/sources.nix` is Pvl-ahead, carrying the extra `pi-codex-limit` record. Mirror of Pvl `8667e21c`, `c50e67e7`, `cad4986a`. |
|  3 | `f9b99a9b` | `chore(vscode): update to 1.139.0`                    | adopted | `lib/ext/vscode/sources.nix` byte-identical; Abird mirror of Pvl `36cebe47`.                                                                                                                                                     |
|  4 | `8f2a6d13` | `test(flake): generalize reserved-directory fixture`  | adopted | `lib/flake/tests/configuration-family.nix` byte-identical; Abird mirror of Pvl `7c8ef98d`. This removed the last repository-specific shared test divergence.                                                                     |
|  5 | `92ecc674` | `docs(parity): record Pvl post-2439daec port`         | skipped | Abird-side port ledger only; the equivalent Pvl record is the existing projection port note.                                                                                                                                     |
|  6 | `23f43aae` | `docs(parity): record post-2439daec publication`      | skipped | Abird publication history only.                                                                                                                                                                                                  |
|  7 | `e275226c` | `feat(ai): prefetch models before activation`         | adopted | All shared AI, host-manager, and Nixbot files byte-identical; Abird mirror of Pvl `18e548f3`. Only `hosts/abird-srv/**` consumers are Abird identity.                                                                            |
|  8 | `e8e24d4b` | `feat(ext): add revdiff TUI and Pi package`           | adopted | `lib/ext/revdiff/**` byte-identical; Abird mirror of Pvl `bb3403c4`.                                                                                                                                                             |
|  9 | `4443d904` | `feat(pi): add pi-diff extension`                     | adopted | `lib/ext/pi/pi-diff/default.nix` byte-identical; `lib/ext/pi/{sources.nix,update.sh}` are Pvl-ahead via `pi-codex-limit`. Mirror of Pvl `a0e0d100`.                                                                              |
| 10 | `78e0eb1c` | `feat(ext): add agent-workspace-linux package`        | adopted | `pkgs/ext/agent-workspace-linux/**` byte-identical and its `pkgs/manifest.nix` registration is present; Abird mirror of Pvl `e9b813b5`. Manifest otherwise diverges only on repository-owned package sets.                       |
| 11 | `7fff009b` | `docs(tooling): record pvl post-d77d1773 shared port` | skipped | Abird-side port ledger, app notes, and git-skill section only; Pvl owns the equivalent originals.                                                                                                                                |
| 12 | `278a2cba` | `style: fix lint`                                     | skipped | Abird documentation lint only.                                                                                                                                                                                                   |

No shared unit was dropped: every commit either maps to a byte-exact shared path
in Pvl or is source-only docs/identity.

## Logical units

1. **PI extension sources and npm fetcher v2 (`2bba63f9`).** The shared PI
   derivations and source pins are present; the Pvl-only `pi-codex-limit` record
   is a Pvl addition, not an Abird change.
2. **NVIDIA production-branch discovery (`44766d09`).** The `unix.md`
   Markdown-representation updater is byte-identical; the driver pin stays a
   repository-owned divergence.
3. **VS Code 1.139.0 (`f9b99a9b`).** Sources file only; the consuming package is
   generic.
4. **Shared projection test neutrality (`8f2a6d13`).** The repository-neutral
   `../../../config` fixture is now identical in both repositories.
5. **`revdiff`, `pi-diff`, `agent-workspace-linux` (`e8e24d4b`, `4443d904`,
   `78e0eb1c`).** All three external units and their updaters are byte-exact.
6. **AI model prefetch (`e275226c`).** The AI prefetch module, catalog,
   backends, projection, `model-prefetch.sh`/`model-prefetch-cache.py`, tests,
   host-manager fleet changes, and Nixbot integration are all byte-exact.
7. **Abird ledgers (`92ecc674`, `23f43aae`, `7fff009b`, `278a2cba`).**
   Documentation only.

## Parity inventory

Byte-plus-mode comparison of tracked common paths under `lib/**`, `pkgs/**`, and
`scripts/**` between `abird/master` (`278a2cba`) and Pvl `HEAD` (`0be0bf94`):

| Scope        |  Common | Byte+mode exact | Differing | Mode diffs | Pvl-only | Abird-only |
| ------------ | ------: | --------------: | --------: | ---------: | -------: | ---------: |
| `lib/**`     |     276 |             266 |        10 |          0 |       41 |         15 |
| `pkgs/**`    |     287 |             283 |         4 |          0 |        6 |        280 |
| `scripts/**` |      21 |              21 |         0 |          0 |        0 |          2 |
| **Total**    | **584** |         **570** |    **14** |      **0** |   **47** |    **297** |

The 14 content differences are all explained and unchanged in kind from the
prior audits:

| Path                                         | Direction           | Cause                                                                                                                |
| -------------------------------------------- | ------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `lib/ext/nvidia/sources.nix`                 | repository-owned    | Pvl driver pin/policy divergence.                                                                                    |
| `lib/ext/pi/sources.nix`                     | Pvl-ahead           | Pvl adds the `pi-codex-limit` npm record.                                                                            |
| `lib/ext/pi/update.sh`                       | Pvl-ahead           | Pvl adds the `pi-codex-limit` update branch.                                                                         |
| `lib/flake/repo-checks.nix`                  | repository identity | Pvl imports `tests/pvl`; Abird imports `tests/abird` plus Abird promotion checks.                                    |
| `lib/hardware.nix`                           | Pvl-ahead           | Pvl desktop hardware/firmware enablement.                                                                            |
| `lib/installer/config/default.nix`           | Pvl-ahead           | Pvl live-installer profile and host targets.                                                                         |
| `lib/locale.nix`                             | Pvl-ahead           | Pvl geoclue2 demo-agent/beacon policy.                                                                               |
| `lib/network.nix`                            | Pvl-ahead           | Pvl systemd-resolved Cloudflare DNS/DoT/DNSSEC policy.                                                               |
| `lib/sudo.nix`                               | Pvl-ahead           | Pvl sudo timestamp policy.                                                                                           |
| `lib/systemd.nix`                            | Pvl-ahead           | Pvl suspend unit start-limit policy.                                                                                 |
| `pkgs/manifest.nix`                          | repository-owned    | Abird product exports vs Pvl `codex-wrapper`/`tuicr`; the in-window `agent-workspace-linux` line is present in both. |
| `pkgs/README.md`                             | repository-owned    | Per-repository package-set documentation.                                                                            |
| `pkgs/cloudflare-apps/README.md`             | Pvl-ahead           | Pvl encrypted-tfvars secret path documentation.                                                                      |
| `pkgs/cloudflare-apps/llmug-hello/README.md` | Pvl-ahead           | Pvl secret-tree path documentation.                                                                                  |

The generic shared trees are fully byte- and mode-identical, including
`lib/incus/**` (all nine tracked files, including tests), `lib/services/ai/**`,
`lib/validation/**`, `pkgs/tools/abird-host-agent/**`,
`pkgs/tools/abird-host-manager/**`, and `pkgs/tools/nixbot/**`.

## Out-of-scope observations

- `lib/systemd-user-manager/**` does not exist at either tip; the legacy manager
  is already retired in both repositories. `lib/sway.nix`,
  `lib/services/excalidash/**`, `lib/services/kanidm/tests/gap3.nix`, and the
  two `scripts/support/abird-*` scripts are Abird-only identity/test surfaces
  already documented as excluded.
- Abird-only generic-looking packages (`pkgs/tools/postgres-queue/**`,
  `pkgs/tools/sqlite-queue/**`, `pkgs/examples/edi-ast-parser-rs/**`,
  `pkgs/labs/**`, `pkgs/srv/{llm,search}/**`) remain documented ownership
  exclusions; they are Abird product units, not shared parity gaps.
- Abird-only generic documentation
  (`.agents/docs/lang-patterns/{rust,terraform}.md` and the
  internal-reachability, live-mutation, registry-DNS-rollout, and
  stateful-contract design patterns) is not a `lib/`/`pkgs/` parity dependency
  and was not ported; it is a possible future documentation-adoption decision,
  not a code gap.

## Validation

- Parity was computed independently by the orchestrator and by three read-only
  subagent lanes (window commit analysis, `lib/**`+`scripts/**` parity,
  `pkgs/**`+docs parity); all three concurred that no Abird-authored shared
  change is unported and that all 14 differences are Pvl-ahead or
  repository-owned.
- `lib/**`, `pkgs/**`, and `scripts/**` were compared by Git `mode:blob` for all
  584 common paths; 570 are exact and there are zero mode differences.
- No code changed, so no build, deployment, or live mutation was run. The
  in-window doc payloads that are shared (`ai-model-prefetch.md`,
  `ai-model-ownership.md`) were confirmed byte-identical; the Abird app notes
  are intentionally repository-adapted.
