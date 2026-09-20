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
handoffs update state immediately with an atomic replacement.

State loss is intentionally leak-safe: it can retain managed bytes, but it
cannot authorize deletion of manual bytes. Do not reconstruct state by scanning
the backend inventory or filesystem cache.

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
