# AI Hardening Fix Validation, 2026-09-22

## Scope

Fresh review of the five commits on top of `c2bbf582` (`8f5d63f3..2f8954a4`):
the recorded review notes, the Prism package/updater hardening, the NATS
fail-closed change, and the centralized AI model policy. The goal was to confirm
the prior review findings are addressed and to look for regressions in the new
code. No code was changed by this pass.

## Disposition of prior findings

| Finding | Status    | Notes                                                                                    |
| ------- | --------- | ---------------------------------------------------------------------------------------- |
| F1      | Fixed     | `configuredBackends` requires a valid ref and a deployment; probes/tests confirm.        |
| F2      | Partial   | Module no longer exposes a projection surface, but `mkProjection.aiServices` still omits |
|         |           | `catalog` (see N1).                                                                      |
| F3      | Fixed     | Unresolved ports are `null`, filtered before collision checks; exact-message test added. |
| F4      | Fixed     | `github_api` adds bearer auth + UA; fake-curl test added.                                |
| F5      | Fixed     | One resolver validates ids, selection keys, and per-backend/per-runtime refs.            |
| F6      | Addressed | Ports retained for mutable clients; the `12001` forward conflict is documented.          |
| F7      | Fixed     | Diagnostics gate emissions; `policy.valid` replaces ad-hoc admission.                    |
| F8      | Fixed     | Option and cache paths corrected in the reconciler note.                                 |
| F9      | Fixed     | `defaults` is null-safe; no raw missing-attribute throw.                                 |

## New / remaining findings

### N1 (Medium): `mkProjection.aiServices` still drops `catalog`

`projection.nix:439` returns `aiServices = {models; roles; backends;}` and still
omits the `catalog` argument used to resolve them. Verified by direct eval:
`aiServices` keys are `[backends models roles]`,
`aiServices ? catalog == false`. A repository that bridges
`services.ai = proj.aiServices` with a custom catalog silently reverts to the
built-in catalog. `backends` is also whatever shape the caller passed, so a
caller reusing evaluated module backends still hits the read-only
multiple-definition error. Include `catalog` (and ideally assert the bridge is a
complete input shape) or document the bridge as
`proj.aiServices // {inherit (proj) catalog;}`.

### N2 (Low/Medium): preset validation is not fully centralized

`projection.nix:28` `validPreset` only requires an attrset of string values and
rejects `alias`/`embeddings`/`hf`. It does not reject empty strings or embedded
newlines. Verified: a preset `threads = "a\nb"` yields `policy.valid == true`,
no diagnostics, and `runtimes.default.modelPresets` contains the newline value.
A malformed `models.ini` is only caught later by the reconciler's own
`presetEntries` assertion for active runtimes (and never for an inactive runtime
whose `deploymentsInfo.<instance>.modelPresets` is still exposed). Mirror the
reconciler's non-empty/single-line/key-pattern checks in the resolver.

### N3 (Medium, design decision to confirm): whole-catalog validation disables every host

Identity, ref, runtime, and preset validation run over the entire catalog, not
the selection (`projection.nix:177-195`). Verified: a catalog with a valid
selected entry plus an unselected entry missing `id` yields
`policy.valid == false` and an `invalid-catalog-entry` diagnostic. Because
`ollamaActive`/`runtimeEnabled` require `policy.valid`, one malformed unselected
entry disables all model reconciliation for the host. This is stricter than the
previous selected-only validation. It is defensible as catalog consistency, but
the operational impact should be explicit: either accept "the whole catalog must
be well-formed", or scope fatal diagnostics to selected entries and keep the
rest advisory.

### N4 (Low, intended behavior change): unknown llama runtime is hidden when Ollama serves the entry

`unknownRuntimeEntries` requires the entry to lack configured Ollama membership,
so an entry with a typo'd `llama.runtime` but a working Ollama ref is now valid
with no diagnostic. The hardening note states this was deliberate ("an unused
llama capability does not invalidate a model served by Ollama"). Confirm this is
the intended loss of the typo signal, since it is the one diagnostic the earlier
design called out as worth failing on.

### N5 (Low): legacy policy helpers remain beside the resolver

`lib/services/ai/default.nix` still defines `missingRefs`, `projectModels`, and
`llamaPresets` (with their own duplicate asserts), and `projection.nix` still
defines `servableModels`/`mkProjection`. Only tests exercise them now; the
module uses `resolvePolicy`. This is dead-weight divergence risk. Either fold
the remaining callers onto the resolver or clearly mark the helpers as the pure
consumer API.

### N6 (Cross-repo risk): removal of `services.ai.projection` is a breaking API change

The shared module replaced the `services.ai.projection` option with
`services.ai.resolvedModels`. The hardening note says Abird derives its
`aiServices` from the same resolver, so this should be intentional, but any
Abird host still reading `config.services.ai.projection.*` will break. Confirm
the port landed on the Abird side.

## Validation evidence

- Built `lib-ai-{lib,module,projection}`,
  `lib-flake-{nats-streams-seams,repo-modules,isolated,service-placements}`,
  `lib-prism-llama-cpp-{package,updater}`, `lib-nix-repo-registry`,
  `lib-llama-router-module`, and `pvl-flake-isolated`: all pass.
- All seven Pvl host configurations evaluate with an empty failing-assertion
  list (`pvl-a1`, `pvl-l5`, `pvl-x2`, `pvl-vk`, `pvl-vk-1`, `pvl-vlab`,
  `pvl-vlab-1`).
- `pvl-a1` resolves 8 models; the `default` runtime keeps the 7 non-Bonsai refs
  and `prism` holds only the Bonsai ref, with distinct caches
  (`/var/lib/pvl/ai/llama-router{,-prism}`), ports (`11000/12000` vs
  `11001/12001`), and separate `models.ini` files.
- Real `natscli 0.4.0` against a local `nats-server 2.14.4`: `stream ls --json`
  returns `null` for no streams and `["NAME"]` after creation;
  `stream info
  --json` matches the
  `subjects`/`storage`/`retention`/`max_consumers` checks. The fake-CLI seam
  test therefore mirrors the real contract.
- Direct probes: `aiServices` lacks `catalog` (N1); a newline preset passes
  validation (N2); an unselected bad entry invalidates the policy (N3); an
  Ollama-served entry with an undeclared runtime is valid with no diagnostic
  (N4).
- `git diff --check c2bbf582..HEAD`, `bash -n`, `shellcheck` on the Prism
  updater, and `deno fmt --check` on the docs: clean.

## Residual risks

- The NATS end-to-end path was not run against a TLS server; only the CLI JSON
  contract was verified live.
- The Prism release hashes were not re-fetched.
- The container `/app` swap still assumes the stock image entrypoint is
  `/app/llama-server`; the new `bin/llama-server` wrapper is an in-store
  convenience and is not what runs in the container.
- Cross-repository byte parity and the Abird port were not re-diffed.
