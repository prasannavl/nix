# AI Model Ownership and Reconciliation

## Ownership boundary

Model presence and model ownership are different facts. The backend inventory is
shared by declarative policy, operators, and other tools, so reconciliation must
never infer deletion authority from inventory alone.

| Model state                                        | Reconciler behavior                                           |
| -------------------------------------------------- | ------------------------------------------------------------- |
| Declared and absent                                | Download it and record its exact backend reference as managed |
| Declared and present                               | Adopt its exact reference as managed                          |
| Undeclared and absent from the ownership manifest  | Leave it untouched                                            |
| Undeclared and present in the ownership manifest   | Delete that exact reference through the backend API           |
| Undeclared, owned, and listed in `preservedModels` | Retain it and relinquish ownership                            |

This makes the managed selection authoritative while preserving ad-hoc
downloads. An operator may download and run any undeclared model through Ollama,
llama.cpp, or another cache-aware tool; it remains reusable until the operator
removes it. The same exact reference cannot be both managed and manual at once.
Declaring a previously manual reference adopts it. Use `preservedModels` for a
managed-to-manual handoff when removing the reference from policy.

## Ownership manifest

Each backend keeps a small persistent manifest containing only exact references
that the reconciler owns. Missing state means no ownership and therefore no
pruning. Malformed, unsupported, duplicate, or unsafe state fails before any
backend request. Successful downloads, adoption, deletion, and preservation
handoffs update state immediately with an atomic replacement. A backend with no
owned references has no manifest, except for an empty migration tombstone while
a legacy manifest remains available for rollback.

This ownership bit is the irreducible state required by the contract. The
backend inventory cannot distinguish a declarative download from an ad-hoc one,
and inferring ownership would authorize deletion of manual data. A systemd
oneshot unit cannot replace the manifest: its active state is lost on reboot, a
host may boot directly into a generation that never activated the removed unit,
and configuration switches execute the old unit's `ExecStop=` by default, which
makes managed-to-manual handoff unsafe. Stateless alternatives must give up
either exact retirement, the shared cache, or manual-model safety.

State loss is intentionally leak-safe: it can retain managed bytes, but it
cannot authorize deletion of manual bytes. Do not reconstruct state by scanning
the backend inventory or filesystem cache.

The user service owns the private manifest directory through `StateDirectory=`
and derives the file from systemd's runtime `$STATE_DIRECTORY`. The AI policy
does not expose a state-path option. Do not provision this state with system
tmpfiles: NixOS switch activation may reconcile user units before
`systemd-tmpfiles-resetup.service`, so a first deployment can race a root-owned
parent directory. Service-managed state ties directory creation directly to each
invocation and works for nonstandard user homes and `XDG_STATE_HOME`.

The transition from the former `/var/lib/<user>/ai/reconciler` location is
fail-closed. When the new manifest is absent, a valid legacy manifest is
imported atomically before backend mutation; an invalid legacy manifest stops
reconciliation. The legacy file remains untouched for rollback compatibility.

## Backend operations

Use supported backend APIs for both acquisition and retirement. Ollama uses its
pull and delete endpoints with canonical tags. The llama.cpp router uses
`POST /models` for cache-only downloads and `DELETE /models?model=...` for an
exact cached reference. Do not delete Hugging Face cache directories: repository
paths are not exact model identities and can contain multiple quantizations.

llama.cpp preset sections use client-facing aliases, leaving the exact Hugging
Face reference available as a cache identity. Downloads remain lazy with respect
to GPU residency; reconciliation caches weights but does not load them.

## Service projection and triggers

The podman-compose instance is authoritative for its user, systemd unit name,
service prefix, and exposed API port. AI policy refers to the instance and may
select a named port only when needed; it must not repeat these values.

Configuration changes schedule or restart reconciliation through the managed
target so a newly loaded policy cannot be hidden by an older active worker. Each
backend service also starts an idle worker after every successful start, so a
manual, stopped, or automatic deployment reconciles its shared store without
starting sibling deployments or interrupting reconciliation already in flight.
The policy dispatcher is the sole restart owner. It observes the complete
systemd restart job and judges terminal worker state only after the queued
stop/start transaction finishes; the expected stopped invocation cannot be
mistaken for failure while its replacement is pending. Workers order after all
candidate backends, select the first reachable API, and exit quickly when every
backend is inactive.

`services.ai.models` is the only model selection list. Catalog references record
backend capability; configured membership additionally requires a non-empty
deployment list for that backend. A llama.cpp reference also requires its
normalized runtime to have a deployment. There are no per-backend override
lists.

`models = null` selects every entry with at least one configured membership. An
explicit selection is checked against the same predicate, so a syntactically
valid reference cannot become silently unserved when its backend or runtime is
absent. A reference for an undeployed backend is harmless when another
configured backend serves the model. A selected entry with no configured
membership fails evaluation.

One pure `analyzeCatalog` function owns fleet-wide catalog admission, including
reference and preset schemas plus duplicate identities. One pure `resolvePolicy`
function consumes that analysis and owns selection, role validation, configured
membership, and the Ollama/per-runtime partitions. It reads only catalog,
selection, roles, and declaration-owned deployment lists. The catalog is
admitted as one policy artifact: a malformed dormant entry is a configuration
failure even when no current host selects it.

The NixOS module maps resolver diagnostics to assertions and must not
reimplement admission. Deployment topology (compose instances, users, service
names, and ports) stays module-owned because it depends on evaluated compose
configuration. The public module surface remains typed and narrow:
`resolvedModels` plus typed backend/runtime projections. The internal diagnostic
record is not a second configuration API.

Repository-level pure projections may derive consumer helpers from the same
resolver result. Their `moduleConfig` handoff is the complete replayable
`services.ai` input: catalog, resolved selection, roles, and declaration-owned
backend fields. It must exclude evaluated/read-only outputs such as ports,
service names, activity flags, and runtime projections.

Catalog client IDs must be valid INI section names and globally unique. Ollama
references are globally unique; llama references and aliases are unique within
each runtime; selection keys are unique; and roles resolve into the admitted
selection. Preset option names and values are non-empty single-line strings. The
resolver and reconciler share one pure preset schema and renderer. Reject all
ambiguities and malformed values before constructing `listToAttrs` maps or
router presets.

llama.cpp engines are named and isolated. An entry's `llama.runtime` selects the
engine: `default` (the upstream llama.cpp build) or a fork such as `prism`. Each
configured runtime under `backends.llamaRouter.runtimes.<name>` owns its own
deployments, cache directory, reconciler state file, reconciler units,
`preservedModels`, and `idleTimeoutSeconds`, so one engine's cache scan or model
set can never leak into another engine. The resolved cache directory must be
unique across runtimes with deployments; deployments of one runtime may share
that runtime's cache. The read-only `backends.llamaRouter.runtimesInfo.<name>`
projection exposes each runtime's resolved `urls`, `ports`, `portsByName`,
`endpoints`, `serviceNames`, `readyTarget`, `requiredModels`, `modelPresets`,
`cacheDir`, and `active`.

`idleTimeoutSeconds` (default `null`) is emitted as the models.ini `[*]`
`sleep-idle-seconds` key for that runtime, so llama.cpp releases a model's
resident weights and KV cache after the idle window instead of holding them
until LRU eviction; the shared `[*]` section also reaches cache-scanned ad-hoc
models.

Consumer addressing is separate from topology. Each deployment may set an
optional `host`; the backend projections expose ordered `endpoints` descriptors
(`instance`, `device`, `port`, `host`). The pure `mkConsumers` accepts
descriptors that are either a `{ host; port; }` pair or a fully resolved
`{ url; }`, and returns the consumer view per backend (`ollama`, `llama`):
ordered `endpoints`, native `urls`, OpenAI `openaiUrls`, required `default` /
`openaiDefault` primaries, and `byDevice` / `openaiByDevice` list lookups keyed
by device class; llama.cpp also carries `apiKeys`. Output endpoint descriptors
normalize an omitted host to `defaultHost`, while a fully resolved URL remains
URL-owned. A missing primary throws one clear message instead of yielding a null
URL, so consumers never guard or coerce. The NixOS module exposes the view as
`services.ai.consumersFor
defaultHost`, while a repository whose addresses live
elsewhere (for example a service registry) calls `mkConsumers` directly with its
own descriptors — abird derives them from `mkApi` so there is a single address
source.

Deployment instance names, resolved service names, API ports, and configured
runtime cache directories must be globally unique across AI backends and
runtimes. An unresolved deployment port is `null`, is omitted from endpoint
projections and collision checks, and is reported by the specific missing-port
or missing-instance assertion rather than a synthetic sentinel collision.

## Closure-safe helper packaging

Every runtime helper must be an explicit member of the generated wrapper's Nix
closure. Backends construct their wrappers through
`model-reconciler.mkApplication`, which injects the ownership helper directly
into context-preserving wrapper text. Do not pass a Nix path through
`runtimeEnv`: its serialization can retain the literal store filename while
dropping string context, producing a wrapper that works only when an unrelated
closure happens to keep that source snapshot.

The shared model-reconciler check executes a factory-built wrapper inside the
build sandbox. This verifies that the ownership helper is reachable through the
declared closure independently of any backend or ambient store path.
