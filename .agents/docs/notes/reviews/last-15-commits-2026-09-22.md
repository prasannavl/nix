# Last 15 Commits Review, 2026-09-22

## Scope

Fresh review of `7073da89..c2bbf582` (`HEAD~15..HEAD`), covering every commit
from `f5a2b566 feat(ai): add llama router idle sleep option` through
`c2bbf582 docs(agents): record abird audit and quadlet blockers`.

The implementation themes were llama-router idle sleep, catalog-derived backend
membership and per-engine runtimes, the PrismML llama.cpp fork, the generic NATS
stream-set factory, repository-module composition, inventory-derived Nix cache
configuration, and the shared AI projection. Documentation-only commits were
also checked against the final evaluated state.

## Findings

### Selected models are not guaranteed to have a serving deployment

`projection.nix::servableModels` treats a catalog entry as llama-servable when
`llamaRuntime entry` names any runtime attribute. `llamaRuntime` defaults to
`default` even when the entry has no valid `llama` reference, and the helper
does not require that the runtime have a deployment. Its Ollama branch likewise
checks for a non-null field instead of a valid backend config.

The module's explicit-selection admission has the complementary gap: `unserved`
checks whether an entry carries any valid Ollama or llama reference, not whether
the corresponding backend/runtime has a deployment. A llama-only model with no
llama runtime, or an Ollama-only model on a llama-only host, can therefore pass
the assertion while no service can serve it. Direct evaluation also showed an
HF-only and Ollama-only entry being returned as llama-servable merely because
`runtimes.default` existed.

Resolve availability once from valid references plus non-empty deployments. Both
nullable auto-selection and explicit-selection assertions should consume that
same result. Keep the separate undeclared-runtime diagnostic when a host
actually deploys llama.cpp so runtime typos remain visible.

### The projection handoff is incomplete and cannot be replayed

`mkProjection` accepts a `catalog` argument, uses it to resolve models and
defaults, then omits it from `aiServices`. A repository following the documented
handoff (`services.ai = projection.aiServices`) therefore falls back to the
module's default catalog. Custom keys fail later as unknown, and same-named keys
can silently resolve to different definitions.

The module also calls `mkProjection` with the evaluated `cfg.backends`, so its
`projection.aiServices.backends` contains derived read-only fields such as
`active`, `ports`, `serviceNames`, `requiredModels`, and the then-named
`runtimesInfo` projection (now `deploymentsInfo`). An independent
`lib.evalModules` round-trip failed on the first such field:
`services.ai.backends.llamaRouter.active` was read-only but set multiple times.

If an input handoff is required, it must be the exact declaration-only shape
`{catalog, models, roles, backends}` with no derived fields. Otherwise remove
`aiServices` and expose only the resolver's output; maintaining a partial second
policy surface is less clear than having consumers call the resolver directly.

### Unresolved deployment ports create a false uniqueness error

`deploymentPort` returns the integer sentinel `1` when an instance or selected
port cannot be resolved. The global uniqueness assertion includes those
sentinels. A harness with two distinct missing llama-router instances therefore
reported the unrelated `deployment API ports must be unique` error in addition
to the two correct missing-instance errors.

Represent an unresolved port as `null`; check uniqueness over resolved ports
only, after stack and instance admission. This is the concrete diagnostic-gating
defect. A broader claim that unresolved deployments produce a long tail of
reconciler failures did not reproduce and should not be counted separately.

### Catalog identity and reference uniqueness are not admitted centrally

Selected entries require only a string `id`; empty and duplicate IDs, duplicate
backend refs, and duplicate model keys in `services.ai.models` are not rejected.
`builtins.listToAttrs` then silently overwrites collisions in `catalogById` and
llama presets, while duplicate llama aliases can survive until router startup
and fail there.

Create one pure catalog/policy validator shared by `projection.nix` and
`module.nix`. Require non-empty unique selected keys and client IDs, valid
backend configs, unique refs per backend/runtime, valid runtime identifiers, and
roles that resolve into the selected set. Do not distribute overlapping partial
validation across projection and module layers.

### The Prism updater bypasses authenticated GitHub requests

The top-level updater normalizes `GH_TOKEN`/`GITHUB_TOKEN` into `GITHUB_TOKEN`,
but `lib/ext/prism-llama-cpp/update.sh` calls the GitHub releases API without an
`Authorization` header. It therefore consumes anonymous quota even in an
authenticated update run and can reproduce the rate-limit failures the token
bridge is intended to prevent.

Build a curl argument array and add `Authorization: Bearer $GITHUB_TOKEN` when
non-empty, matching the existing Neovim updater and source reporters. Cover the
header/no-header cases with a fake-curl updater test without printing the token.

### The Prism CUDA port collides with the persisted VS Code recovery port

`pvl-a1` declares `llama-router-prism-nvidia` on local port `12001`. The
same-day port incident note says the VS Code forward from `pvl-l5:12000` was
persisted on local `12001` as a non-conflicting recovery. Starting the manual
Prism CUDA deployment can therefore recreate the same socket collision.

The service declaration predates the mutable recovery mapping, so keep the
declarative backend port stable and remap/remove the VS Code forward. Update the
port convention ledger to include the Prism `11001`/`12001` pair and state that
mutable forwards yield to declared local services.

### The llama-router note contains pre-runtime paths

The idle-sleep section still names
`services.ai.backends.llamaRouter.idleTimeoutSeconds`; the current option is
`services.ai.backends.llamaRouter.runtimes.<name>.idleTimeoutSeconds`. The host
mapping also retains the former `/var/lib/pvl/llama-router/cache` path instead
of the evaluated default `/var/lib/pvl/ai/llama-router`. Update both so the
durable note does not contradict the runtime note and evaluated configuration.

### Auto-selection order and unknown roles have unclear failure semantics

The `models` option calls the list a pull order, while `models = null` derives
it from `builtins.attrNames catalog`, which is lexicographically sorted. That is
a deterministic default, not catalog-authored priority; document it as such or
add an explicit order field if pull priority matters.

`mkProjection.defaults` also indexes `catalog.${key}` directly. Forcing an
unknown role through the pure projection throws a raw missing-attribute error
before a consumer can inspect structured diagnostics. The resolver should emit a
bad-role diagnostic and return a safe `null`/omitted default on invalid input.

## Design assessment

The per-runtime ownership boundary is the right architecture: each engine has
isolated deployments, cache, reconciler units, manifest, model presets, and
ports, while the default runtime preserves historical names. Mounting the
fixed-output Prism release over the stock image's `/app` is smaller and clearer
than maintaining a second OCI build, and exact-container probes validate the ABI
assumption. The NATS stream-set factory and repository-module registry also
improve ownership and avoid repository-specific policy in shared package code.

The AI projection should not grow another layer of ad hoc checks. The simplest
robust final design is one pure `resolvePolicy` boundary that accepts catalog,
nullable selection, roles, and declaration-only backend capabilities. It should
return a safe resolved selection, role defaults, per-backend/per-runtime model
partitions and presets, plus structured diagnostics for invalid entries, unknown
keys/runtimes, unserved models, duplicate IDs/refs, and bad roles.

The NixOS module should map those diagnostics to assertions and translate only a
valid result into services; it should own no separate servability predicate.
Deployment topology remains a separate concern because its users, instance
names, ports, and readiness targets participate in the Compose/module fixed
point. Resolve those values to `null` until admitted, and run collision checks
only on resolved topology. `services.ai.projection` should expose the same
resolver output. Keep an input-shaped `aiServices` only if a real cross-repo
round-trip consumer exists and a test proves it.

## Validation evidence

- Repository-wide no-IFD `.#lint` completed across all seven affected hosts.
- `lib-ai-{lib,module,projection}`, `lib-flake-repo-modules`,
  `lib-flake-nats-streams-seams`, and `pvl-flake-isolated` checks built.
- `pvl-a1` evaluated with disjoint `default` and `prism` runtime projections,
  ports, presets, cache directories, and required references.
- Both fixed-output Prism variants built. Their hashes equal the release assets'
  published SHA-256 digests.
- Both fork binaries launched inside the exact pinned ROCm/CUDA v0.4.1 images;
  the expected build/commit and router options were present.
- The package-local and top-level Prism reports identified the pin as latest.
- Bash syntax, ShellCheck, per-commit whitespace checks, and range
  `git diff --check` passed.
- Independent module probes reproduced the incomplete `aiServices` shape, its
  read-only round-trip failure, and the sentinel-port diagnostic; a pure probe
  reproduced the raw unknown-role failure and silent duplicate ID/ref collapse.
- The worktree remained clean before this required review note was added; no
  deployment or persistent runtime mutation was performed.
