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

`services.ai.models` is the only host admission list. Catalog references record
backend capability; configured membership additionally requires a non-empty
deployment list for that backend. A llama.cpp deployment may narrow its
placement with `models`, but that filter cannot admit a model outside
`services.ai.models`. There are no independent per-backend catalogs or model
selection lists.

`models = null` selects every entry with an Ollama or llama.cpp configured
membership. An explicit selection may additionally admit a valid Hugging
Face-backed model for a host-owned runtime such as vLLM or SGLang; prefetch does
not imply that admission. A reference for an undeployed backend is harmless when
another configured backend serves the model. A selected entry with no configured
membership or explicit HF source fails evaluation.

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

llama.cpp engines are named and isolated. A catalog entry's optional
`llama.runtimes` list declares every compatible engine; absence means
`[ "default" ]`, the upstream llama.cpp build. A model may therefore run on both
upstream and a compatible fork without duplicating its catalog entry.

The writable API is flat: `backends.llamaRouter.deployments` contains service
records with optional `runtime`, `cacheDir`, `models`, `preservedModels`, and
`idleTimeoutSeconds`, while `backends.llamaRouter.defaults` supplies shared
fallbacks. `runtime` defaults to `default`; `cacheDir` otherwise derives from
the runtime; `models = null` selects every admitted model compatible with the
runtime; and `idleTimeoutSeconds = null` inherits the backend default. A
deployment may use `false` to disable an inherited idle timeout.

Runtime ownership is derived, not configured as another public hierarchy.
Deployments of one runtime must resolve to one cache directory and one systemd
user; their model filters and `preservedModels` are separately unioned for that
runtime's single reconciler and ownership manifest. A preserved model therefore
never leaks into another runtime's retirement policy. Different runtimes must
use distinct canonical cache paths and state files, so one engine's scan or
retirement can never leak into another. Each deployment receives its own
`models.ini`, containing only its placed models and idle policy. The read-only
`backends.llamaRouter.deploymentsInfo.<instance>` projection exposes the
effective runtime, cache, catalog keys, GGUF refs, presets, runtime preservation
union, idle timeout, service name, URL, and port.

A positive `idleTimeoutSeconds` is emitted as that deployment's models.ini
`[*] sleep-idle-seconds` key, so its llama.cpp service releases resident weights
and KV cache after the idle window instead of holding them until LRU eviction.
The `[*]` section also reaches cache-scanned ad-hoc models in that service.

Consumer addressing is separate from topology. Each deployment may set an
optional `host`; the backend projections expose ordered `endpoints` descriptors
(`instance`, `device`, `port`, `host`, exact ordered `modelIds`, and the
resolved `runtime` for llama.cpp). `modelIds` comes from the same per-deployment
policy projection that renders `models.ini`; consumers therefore cannot
advertise a model admitted only to a sibling runtime. The pure `mkConsumers`
accepts descriptors that are either a `{ host; port; }` pair or a fully resolved
`{ url; }`, and returns the consumer view per backend (`ollama`, `llama`):
ordered `endpoints`, native `urls`, OpenAI `openaiUrls`, required `default` /
`openaiDefault` primaries, and `byDevice` / `openaiByDevice` list lookups keyed
by device class; llama.cpp also carries `apiKeys`. The llama.cpp view includes
every configured runtime in deployment order instead of treating the upstream
`default` engine as the only consumer-visible runtime. Output endpoint
descriptors normalize an omitted or explicitly null host to `defaultHost`, while
a fully resolved URL remains URL-owned. Hand-authored descriptors that do not
carry admission context normalize `modelIds` to an empty list. Endpoint order is
deployment declaration order; declare GPU runtimes before CPU fallbacks when
consumers should present CPU last. A missing primary throws one clear message
instead of yielding a null URL, so consumers never guard or coerce. The NixOS
module exposes the view as `services.ai.consumersFor defaultHost`, while a
repository whose addresses live elsewhere (for example a service registry) calls
`mkConsumers` directly with its own descriptors — abird derives them from
`mkApi` so there is a single address source.

The additive cache-warmup path is specified in `ai-model-prefetch.md`. It may
ask current backends or Hugging Face to cache the candidate selection before
activation, but it never writes this reconciler's ownership manifest or performs
retirement.

Deployment instance names, resolved service names, and API ports must be
globally unique across AI backends and runtimes. Configured HF, Ollama, and
per-runtime llama.cpp storage roots must be pairwise non-overlapping by path
component, including equal and ancestor/descendant paths. An unresolved
deployment port is `null`, is omitted from endpoint projections and collision
checks, and is reported by the specific missing-port or missing-instance
assertion rather than a synthetic sentinel collision. All managed storage paths
use the same canonical-safe absolute-path contract before any tmpfiles rule or
preactivation plan is rendered; noncanonical aliases cannot bypass
cache-isolation checks.

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
