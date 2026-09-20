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
backend service also schedules the worker after every successful start, so a
manual, stopped, or automatic deployment reconciles its shared store without
starting sibling deployments. Workers order after all candidate backends, select
the first reachable API, and exit quickly when every backend is inactive.

Backend-specific model selections may extend or replace the shared selection.
Catalog entries require only the references used by the backends that select
them. Deployment instance names, resolved service names, and API ports must be
globally unique across AI backends.

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
