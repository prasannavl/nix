# Abird Post-22e Port, 2026-08

## Scope

- Pvl pre-port tip: `23e8741caab8e03689f78a429a8edbc6baf3dedc` on the primary
  `master` worktree.
- Previous completed Abird audit tip:
  `22e85790ba8c0e18ae2a313246a16ee164c04835`.
- Frozen Abird primary-worktree tip: `c3b359045911f122de43abec2cac242b06bdbc4a`.
- Audit window: `22e85790..c3b35904`, four commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

The existing uncommitted post-`3fcaea2c` audit documentation was preserved.
Abird local `master`, `origin/master`, and the live GitHub ref agreed at the
frozen source tip. Three parallel read-only reviews classified the complete
window and its cumulative shared-path parity before closeout.

## Per-Commit Ledger

|  # | Commit     | Subject                                         | Final disposition                                                                                                                                                                                                                |
| -: | ---------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `7b5b7166` | `docs(agent): add AI workflow planning`         | Skipped: Abird Agentic Phase 3 product planning for immutable objectives, bounded multi-stage plans, revisions, dependent stages, and later fan-out. Pvl has no corresponding product controller or plan.                        |
|  2 | `046cfed8` | `fix(health): converge Quadlet readiness first` | Cleanly ported: four implementation/test files are byte-and-mode exact. The generic readiness rule is adapted into Pvl's condensed service note and README index.                                                                |
|  3 | `fa1e9dcd` | `fix(gap3): extend Zulip readiness budget`      | Skipped: Gap3 measures a 127-second cold Zulip recreation and sets only `hosts/gap3-rivendell/services/zulip.nix` to a 300-second readiness budget. Pvl has no Gap3 host and already documents measured local timeout overrides. |
|  4 | `c3b35904` | `style(docs): format Gap3 incident note`        | Skipped with the absent Gap3 incident note; Markdown-only reflow with no reusable semantic change.                                                                                                                               |

## Logical Port Unit

The shared health-control unit has two ordered parts:

1. `composectl expected-runtime` reads the registry's explicit `readyUnit`,
   verifies that the main service is active, and starts the lifecycle ready
   target. It fails closed when `readyUnit` is missing instead of deriving a
   verifier name.
2. Nixbot performs expected-runtime convergence before expected-unit, failed-
   unit, and transitional-unit sampling. A successful health-owned retry can no
   longer leave the same health pass reporting the stale failure it repaired.

Held main units remain excluded. Pvl currently has no production Quadlet
instance, but it shares the complete provider-transition surface and tests, and
Nixbot remains broadly deployed. The unit is therefore shared lifecycle behavior
rather than Abird topology.

## Exact Shared Files

| Mode     | Blob       | Path                                          |
| -------- | ---------- | --------------------------------------------- |
| `100644` | `4c290dd7` | `lib/podman-compose/composectl.sh`            |
| `100644` | `305d1a7b` | `lib/podman-compose/tests/test_composectl.py` |
| `100755` | `3b646476` | `pkgs/tools/nixbot/nixbot.sh`                 |
| `100644` | `d1cd36c2` | `pkgs/tools/nixbot/tests/test_nixbot.py`      |

The cumulative stable patch ID for these four paths is
`e140b8583acff05a089ad4af605a316bd4a5d975`. The Pvl pre-port blobs exactly
matched Abird's source-window parent, and no later source commit changed them.

## Repository-Owned Exclusions

- `.agents/plans/2026-w33-abird-agentic-durable-agency.md` is Abird product
  planning state.
- `.agents/docs/notes/hosts/gap3-rivendell-zulip-2026-05.md` and
  `hosts/gap3-rivendell/services/zulip.nix` belong to the Gap3 deployment.
- `.agents/docs/README.md` remains the Pvl documentation index.
- Pvl's intentionally condensed
  `.agents/docs/notes/services/podman-compose-ready-repair-2026-07.md` retains
  its local shape while adopting the generic convergence section.

## Parity and Validation

- The Podman Compose helper passed all 173 tests.
- The Podman Compose module check passed.
- The Quadlet generator-lifecycle and provider-transition VM checks passed.
- The Nixbot helper passed all 237 tests on retry. Its first run exposed an
  unrelated unchanged timing assertion that observed `1s` instead of `0s`; the
  exact rerun passed.
- The new Nixbot convergence-order regression passed directly.
- The four code/test paths are byte-and-mode exact at the frozen Abird tip.
- The complete frozen-tip census has 402 common tracked `lib/**` and `pkgs/**`
  paths: 382 byte-and-mode exact, the same 20 established Pvl-owned content
  divergences, and zero mode differences.
- A final refetch found no source commit after `c3b35904`; Abird local,
  tracking, and live GitHub `master` refs agree at that tip.
- `git diff --check` passed.
- No commit or push was performed during this audit.
