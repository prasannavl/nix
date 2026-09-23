# Both-Repo AI Policy Consolidation Validation, 2026-09-22

## Scope

Fresh validation of the latest updates on both main worktrees:

- Pvl `nix` at `c6a4a182`
  (`2158059f fix(ai): consolidate catalog policy
  contract` plus its
  documentation commit).
- Abird at `a7e1b624` (`873e936d fix(ai): consolidate catalog policy contract`,
  `0cf513e6 refactor(abird-srv): consume ai moduleConfig bridge`, plus docs).

The review checks that the consolidation closes the findings from the previous
pass, that the shared contract is byte- and mode-identical across repositories,
and that the Abird consumer bridge works end to end. No code was changed by this
pass.

## Shared-surface parity

The complete AI, llama-router, Prism, NATS, cache, and repository-module trees
compare equal by content and mode. Notable shared files:
`lib/services/ai/{projection,backends,module,catalog}.nix` and its tests,
`lib/services/llama-router/{presets,default}.nix` and its tests,
`lib/ext/prism-llama-cpp/*`,
`scripts/support/tests/test_prism_llama_cpp_update.py`,
`pkgs/support/nats-streams/default.nix`, `lib/nix.nix`,
`lib/flake/repo-modules.nix`, and the shared ownership design document.

Expected divergences are repository identity only: Abird's
`pkgs/support/nats-streams/chat-intelligence.nix` adapter and `specs/`, its
`hosts/abird-srv/services/ai.nix` consumer, and the repository-specific review
notes/index.

## Disposition of the previous pass

| Finding | Status   | Evidence                                                                                  |
| ------- | -------- | ----------------------------------------------------------------------------------------- |
| N1      | Fixed    | `mkProjection.moduleConfig` now carries `catalog` plus `sanitizeBackends` output; probes  |
|         |          | confirm `moduleConfig.catalog` is preserved and derived fields are stripped; a custom     |
|         |          | catalog round-trips through the evaluated module.                                         |
| N2      | Fixed    | `llama-router/presets.nix` owns section-name/option-name/option-value/model-ref schemas;  |
|         |          | tests reject empty, multiline, bad-key, and `alias`-override presets.                     |
| N3      | Accepted | Whole-catalog fail-closed validation is deliberate and now tested; the policy is one      |
|         |          | fleet-wide artifact, so a dormant invalid entry blocks a generation.                      |
| N4      | Accepted | An unused undeclared llama runtime stays harmless when a configured backend serves the    |
|         |          | model; the typo signal is intentionally dropped.                                          |
| N5      | Fixed    | `lib/services/ai/default.nix` and `servableModels`/`aiServices` are removed; callers use  |
|         |          | `resolvePolicy`/`moduleConfig`.                                                           |
| N6      | Fixed    | `services.ai.projection` is gone; the typed `services.ai.resolvedModels` replaces it, and |
|         |          | Abird's host bridge consumes `moduleConfig`.                                              |

Also confirmed from the earlier pass: unresolved ports are `null` and excluded
from collision checks, the Prism updater authenticates its GitHub API lookup,
and the NATS ensure unit fails closed on drift.

## End-to-end validation

- Built the focused checks in both repositories: AI lib/module/projection,
  llama-router module, Prism package/updater, NATS stream-set seams, and the
  Abird registry identity checks. All pass.
- All seven Pvl hosts (`pvl-a1`, `pvl-l5`, `pvl-x2`, `pvl-vk`, `pvl-vk-1`,
  `pvl-vlab`, `pvl-vlab-1`) evaluate with an empty failing-assertion list.
- Representative Abird hosts (`abird-srv`, `abird-dev-srv`, `abird-corp`,
  `abird-gondor-srv`) evaluate with an empty failing-assertion list.
- `abird-srv` resolves 15 models, keeps the custom cache
  `/var/lib/abird/ai/llama-router`, projects port `11436`, generates a
  `models.ini` with the expected presets, and creates `/var/lib/abird/ai` plus
  `/var/lib/abird/ai/llama-router` owned by `abird`.
- `pvl-a1` keeps disjoint default (7 refs) and Prism (Bonsai-only) runtimes with
  distinct caches (`/var/lib/pvl/ai/llama-router{,-prism}`), ports
  (`11000/12000` vs `11001/12001`), and `models.ini` files.
- The Prism `mainProgram` removal is justified: the release `llama-server`
  interpreter is `/lib64/ld-linux-x86-64.so.2`, so it is a container payload,
  not a native Nix host executable. A previously added host wrapper would have
  been misleading.
- The pending `ai-backend-port-scheme-2026-09.md` plan's D6 assumptions hold
  against the current module: multiple deployments per runtime, one `models.ini`
  per runtime staged into every deployment, cache uniqueness per runtime, and
  global instance/port uniqueness.

## Remaining minor observations

- `lib/services/ai/backends.nix::validLlamaRuntime` is defined but unused; the
  resolver uses `projection.nix::validRuntime`. `missingKeysFrom` is test-only.
  Harmless, but dead surface.
- `sanitizeBackends`/`sanitizeDeployment` hardcode the declaration-only field
  lists. Adding a deployment or runtime option requires updating the sanitizer,
  or the `moduleConfig` bridge silently drops it. A round-trip test that sets
  every declaration field would catch omissions.
- Removing the `runtimeNames == []` guard changed the diagnostic for a
  llama-only selection on a host with no runtimes from `unserved-model` to
  `unknown-llama-runtime`. No real host is affected; the tests encode the new
  behavior.
- `prismLlamaCppPackageTest` asserts the _absence_ of `meta.mainProgram`
  (evaluating `test "false" = false`), which is a little opaque; a comment would
  make the intent clearer.

## Residual risks

- The NATS drift path was verified against the real `natscli 0.4.0` JSON
  contract earlier but still not exercised end to end over TLS.
- Prism release hashes were not re-fetched.
- Broader non-AI cross-repository byte parity was not re-diffed in this pass.
