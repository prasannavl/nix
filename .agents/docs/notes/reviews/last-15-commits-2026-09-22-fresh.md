# Last 15 Commits Review (Fresh Pass), 2026-09-22

## Scope

Independent re-review of `f5a2b566..c2bbf582` (15 commits) covering llama-router
idle sleep, catalog-derived backend membership with per-engine runtimes, the
vendored PrismML llama.cpp fork, the generic NATS stream-set factory,
repository-module composition, the inventory-derived Nix cache registry, and the
shared AI projection.

A first-pass note exists at `last-15-commits-2026-09-22.md`. This pass
re-derived every finding from the final tree and by direct evaluation, confirmed
the first-pass items, and records additional issues the first pass did not cover
(F3, F6, F7, F9). No code was modified; only this note and the docs index entry
were added.

## Verification method

- Read the final state of every non-doc file changed in the range.
- Evaluated the pure projection directly with `nix eval`.
- Evaluated the real NixOS module with a `lib.evalModules` harness built from
  the module-test stub, including round-trip and missing-instance scenarios.
- Built checks `lib-ai-{lib,module,projection}`,
  `lib-flake-{repo-modules,nats-streams-seams}`, `lib-nix-repo-registry`, and
  `pvl-flake-isolated`.
- Ran `git diff --check` over the range, plus `bash -n` and `shellcheck` on the
  Prism updater.

## Findings

### F1 (High, correctness): `servableModels` treats every entry as llama-servable

`lib/services/ai/projection.nix:11` decides llama servability with
`builtins.elem (backendLib.llamaRuntime entry) (builtins.attrNames runtimes)`.
`llamaRuntime` returns `"default"` whenever the entry has no valid `llama` ref,
so any host that declares a `default` runtime marks every catalog entry with an
Ollama-only or HF-only shape as llama-servable too.

Direct evaluation with a synthetic catalog (`a` = Ollama-only, `b` = HF-only,
`c` = llama-only) and `runtimes = {default = {};}` returned `[ "a" "b" "c" ]`;
the correct answer is `[ "c" ]`.

The module compounds this. `module.nix` derives `resolvedModels` from
`servableModels`, but its explicit-selection admission (`hasBackend`/`unserved`)
checks for a _valid_ ref. Results:

- An Ollama-only entry on a llama-only host is auto-selected, passes `unserved`
  because it carries an Ollama ref, and is then filtered out of every
  `runtimeSelected` list. The model is selected but no active backend serves it.
- An HF-only entry on a host with any default runtime fails evaluation with
  `selected models declare no backend reference`, even though the user never
  selected it. A `models = null` host should not fail because the shared catalog
  gained an HF-only entry.

Fix: resolve availability once from valid refs _and_ non-empty deployments, and
have both auto-selection and explicit admission consume that single result. The
llama predicate must require a valid llama ref _and_ a declared runtime.

### F2 (High, correctness/design): `projection.aiServices` is not a usable handoff

`projection.nix:94` returns `aiServices = {models; roles; backends;}`. Two
independent defects:

1. It omits the `catalog` argument it used to resolve models and defaults, so a
   repository forwarding it to `services.ai` silently reverts to the built-in
   catalog and resolves the same keys differently.
2. `backends` is the module's evaluated option value, which carries the derived
   read-only fields (`active`, `serviceNames`, `urls`, `ports`, `portsByName`,
   `readyTarget`, `requiredModels`, and the runtime equivalents). Evaluating the
   module and feeding `config.services.ai.projection.aiServices` back into
   `services.ai` fails with
   `The option ... is read-only, but it's set multiple
   times`.

Probed module output: `aiServices` keys are `[backends models roles]`,
`backends.ollama` keys include `active`, `ports`, `portsByName`, `readyTarget`,
`requiredModels`, `serviceNames`, `urls`, `hasCatalog = false`, and the
round-trip eval fails.

The field is also undocumented: no `.agents/docs` file mentions `aiServices`
(the first-pass note called it a "documented handoff"; that documentation does
not exist). Either make `aiServices` the exact, complete input shape
`{catalog, models, roles, backends}` with no derived fields, or drop it and let
repositories call the pure resolver directly.

### F3 (Medium, robustness): unresolved deployment ports collapse to the sentinel `1`

`module.nix:221` returns port `1` when a deployment's port cannot be resolved.
The uniqueness assertion at the end of the file ranges over every deployment's
`deploymentPort` without excluding unresolved ones. Two deployments whose
podman-compose instances are missing (or a host with no `stack.name`) therefore
both report port `1` and trip the unrelated
`deployment API ports must be unique across backends and runtimes` assertion on
top of the real `has no matching podman-compose instance` error.

Probed with two named-but-missing llama instances: the failing assertions were
the spurious ports message plus the two correct missing-instance messages. Use
`null` for unresolved ports and compute uniqueness over resolved ports only, or
gate the check on `stackReady`.

### F4 (Medium, robustness): the Prism updater bypasses authenticated GitHub requests

`scripts/update.sh` normalizes `GH_TOKEN`/`GITHUB_TOKEN` into `GITHUB_TOKEN`,
exports it to child updaters, and adds `extra-access-tokens` to `NIX_CONFIG` for
Nix. `lib/ext/prism-llama-cpp/update.sh:148` still calls
`https://api.github.com/repos/PrismML-Eng/llama.cpp/releases` with a bare
`curl -fsSL`, so the default "latest release" path (and `--report`) consumes
anonymous quota and can hit the rate limit the token bridge exists to prevent.
`nix store prefetch-file` in `prefetch_artifact` does receive the token via
`NIX_CONFIG`, so only the API call is exposed.

Fix: build a curl argument array and append
`-H "Authorization: Bearer ${GITHUB_TOKEN}"` when non-empty, mirroring
`lib/ext/neovim-plugins/update.sh:134`; cover header/no-header with a
fake-`curl` updater test without printing the token.

### F5 (Medium, correctness): catalog and selection identity are not admitted centrally

Selected entries require only a string `id`. Duplicate client IDs, duplicate
per-backend refs, and duplicate model keys are not rejected centrally:

- `catalogById` (`projection.nix:24`) and `llamaPresets`
  (`lib/services/ai/default.nix`) use `builtins.listToAttrs`, so duplicate keys
  silently overwrite.
- Duplicate `id`s across entries survive into the Ollama tag list and the OpenAI
  proxy map; duplicate llama aliases only fail later in the router reconciler
  (`model preset aliases must be unique`), and duplicate refs _with the same id_
  are silently collapsed.

Fix: one pure catalog/policy validator shared by `projection.nix` and
`module.nix`, requiring non-empty unique selected keys and client IDs, valid
backend configs, unique refs per backend/runtime, valid runtime identifiers, and
roles that resolve into the selected set. Do not distribute overlapping partial
validation across the two layers.

### F6 (Medium, integration): Prism CUDA port `12001` collides with the recovered VS Code forward

`hosts/pvl-a1/services/llama-router.nix:135` publishes
`llama-router-prism-nvidia` on `12001`. The same-day port-incident note
(`pvl-ai-backend-port-convention-2026-09.md:82`) records that recovery moved the
VS Code forward to "local `12001`, and persisted that non-conflicting mapping".
At that date `12001` was _not_ free on `pvl-a1`: it is the manual Prism/CUDA
router port. Starting that router or re-triggering the forward reintroduces the
same class of socket collision the note documents.

The port-convention note still lists only `11000`/`12000` for llama.cpp and only
the non-Prism client profiles, so the two notes describe different port maps.
Reconcile them: either move the Prism pair off the `+1` slots (the Bonsai note
chose adjacency for legibility, not necessity) or record the Prism providers and
the `12001` forward constraint explicitly in the port-convention note.

### F7 (Low, diagnostics): assertions fire without deployment gating

Because `runtimeRequired`, `runtimeModelPresets`, and the reconciler bindings
are computed whenever `selectionValid` holds, a host with missing or mixed-user
deployments emits a long tail of model-reconciler assertions that are not the
actual fault (observed with the missing-instance probe). The `ports` case is F3;
the general pattern is that backend/reconciler assertions are not gated on
`stackReady && deployment resolvable`. Gate them or report a single root cause.

### F8 (Low, docs): stale option and cache paths in the llama-router note

`llama-router-model-reconciler-2026-09.md:139` names the pre-runtime option
`services.ai.backends.llamaRouter.idleTimeoutSeconds`; the current option is
`...runtimes.<name>.idleTimeoutSeconds`. Line 198 names the cache at
`/var/lib/pvl/llama-router/cache`; the evaluated default is
`/var/lib/pvl/ai/llama-router`. Update both so the durable note matches the
evaluated configuration and the newer
`llama-runtimes-membership-by-ref-prism-2026-09.md`.

### F9 (Low, clarity): auto-selection order and raw role failure

The `models` option is documented as "in pull order", but `models = null`
resolves through `builtins.attrNames catalog` (sorted keys), not a curated
order. Also `projection.defaults` indexes `catalog.${key}` directly, so forcing
it with an unknown role key throws a raw missing-attribute error instead of the
module's `badRoles` assertion message. Both are latent.

## Design assessment

The direction is right and most of the implementation is careful:

- **Per-runtime isolation** is the correct ownership boundary. Each engine owns
  its deployments, cache, reconciler state/units, presets, and ports, and the
  `default` runtime preserves historical names. The cycle-avoidance trick in
  `module.nix` (static content keys, runtime list forced only inside option
  values, `models.ini` assignment feeding the same compose instances the
  projection reads) is subtle but correctly documented and validated.
- **Prism vendoring** as a fixed-output release bind-mounted over `/app` is
  smaller and clearer than a second OCI build; the RUNPATH/`$ORIGIN` assumption
  is explicitly recorded as a residual risk.
- **NATS stream-set factory** removes repository policy from shared package code
  while keeping the generic package byte-identical; the bound-module factory
  avoids the package/`config` fixed point.
- **Repository-module composition** is a real improvement over
  `extraCommonModules`: paths only, fail-closed validation, canonical
  `stackName` selection, deterministic ordering, and `repoModulePkgs` to avoid
  forcing config-derived `pkgs` during static collection.
- **`lib/nix.nix` registry projection** removes the hardcoded Pvl cache URL, but
  still hardcodes both builder public keys; the registry record carries no key,
  so a third repository cannot supply one through the seam. Low impact, but the
  abstraction is incomplete.

The AI layer is where the extra complexity is now concentrated. Servability and
admission are reimplemented in `projection.nix` and `module.nix` with different
predicates (F1, F5), and the exported handoff is neither complete nor
module-safe (F2). That is the main design debt to pay down.

## Recommended target design

Collapse the policy layer into one pure resolver, consumed by both the module
and any repository projection:

```nix
resolvePolicy = { catalog, models, roles, backends }: {
  selection;          # null models -> entries with a valid ref for a deployed backend
  defaults;           # role -> entry, tolerant of null/unknown keys
  ollama;             # { required; preserved; }
  runtimes;           # name -> { required; presets; cacheDir; globalPreset; }
  diagnostics;        # unknownKeys, invalidEntries, unserved, unknownRuntime,
                      # duplicateIds, duplicateRefs, badRoles
};
```

- `module.nix` maps `diagnostics` to assertions and translates the resolved
  partitions into services; it owns no servability logic of its own.
- `services.ai.projection` exposes the same resolved value; if `aiServices`
  remains, it must be the exact complete input shape (including `catalog`) with
  no derived/read-only fields.
- Validate catalog identity and reference uniqueness in the resolver, not in the
  router reconciler.
- Resolve ports to `null` when unresolved and gate diagnostics on `stackReady`.

Alternatives: if the handoff is not actually needed across repositories, delete
`aiServices` and have consumers call `resolvePolicy`/`mkProjection` directly;
the module already exposes the per-backend `requiredModels`/`deploymentsInfo`
views. That is simpler than maintaining a second, partial policy surface.

## Validation evidence

- `nix build` of `lib-ai-lib`, `lib-ai-module`, `lib-ai-projection`,
  `lib-flake-repo-modules`, `lib-flake-nats-streams-seams`,
  `lib-nix-repo-registry`, and `pvl-flake-isolated`: all pass.
- `nix eval` probes: `servableModels` returns `[a b c]` for the synthetic
  Ollama-only/HF-only/llama-only catalog; `aiServices` lacks `catalog` and its
  `backends.ollama` carries read-only derived fields; the module round-trip
  fails; two missing instances produce the spurious ports-uniqueness assertion.
- `git diff --check f5a2b566~1..HEAD`, `bash -n`, and `shellcheck` on
  `lib/ext/prism-llama-cpp/update.sh`: clean.
- `deno fmt` applied to this note.

No deployment, restart, or persistent runtime mutation was performed.

## Residual risks / not independently verified

- The Prism release hashes were not re-fetched; the first-pass note's
  digest-match checks were not repeated here.
- Live container/ABI behavior of the fork bind-mount and `--sleep-idle-seconds`
  was not re-executed.
- Cross-repository byte parity for `lib/**`, `pkgs/**`, and `scripts/**` was not
  re-diffed; only this repository's tree was reviewed.
