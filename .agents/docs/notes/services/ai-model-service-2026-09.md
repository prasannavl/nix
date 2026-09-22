# Shared AI Model Service (`services.ai`), 2026-09

## Decision

AI model policy moves out of the per-backend service files into a single
`services.ai` host option, implemented by `lib/services/ai` (module, catalog,
and pure helpers). The lib is byte-shared with the abird upstream stack:
identical files, byte for byte, in `lib/services/ai/` of both repositories.
Stack identity comes only from `services.ai.stack.name`, which the stack's
common host profile sets (`pvl` here, `abird` there).

Host files split into two planes:

- `hosts/<host>/services/ai.nix` (policy plane): catalog selection (`models`),
  role pointers (`roles.main`, `roles.smallTask`, `roles.embedding`), and
  per-backend `deployments` (name, port, lifecycle).
- `hosts/<host>/services/<backend>.nix` (machine plane): container definition
  only — image, devices, GPU tuning, port binds, volumes. Ports, volumes, and
  Web UI backend URLs are read back from `services.ai` instead of being
  restated.

The module derives and owns everything the reconcilers previously wired by hand:
unit names (`${stack}-ollama-models`, `${stack}-llama-router-models` —
unchanged), pull lists per backend reference field, `models.ini` presets for
llama-router deployments, `ollamaUrls`/`reconcileTriggers`/`readyTarget`
reconciler arguments, lifecycle (`auto`, `manual` → `autoStart = false`,
`stopped` → `state = "stopped"`), the shared models dir, and tmpfiles rules.

## Contract

- `services.ai.models` is a nullable list of catalog keys; null selects every
  model with at least one configured backend deployment, and unknown keys fail
  evaluation.
- `roles` are keys into the same selection; roles pointing outside the selection
  fail evaluation (null defaults, hosts opt in).
- A backend activates only when its `deployments` list is non-empty. Catalog
  references record capability; configured membership requires a valid reference
  and a deployment, plus the matching runtime deployment for llama.cpp. Each
  deployment must have a matching host-declared `podman-compose` instance (the
  module asserts `source != null`); the module never declares compose sources.
- Pulls run through the running backend's API, so the shared Ollama models dir
  (and the llama.cpp cache dir) are mounted read-write into the containers;
  whichever deployment performs a pull, blobs land once in the shared location
  and every deployment serves them.
- Backends take multiple deployments sharing one storage location: the dual-GPU
  hosts run an AMD and an NVIDIA variant side by side (mirroring
  `ollama`/`ollama-nvidia`), with the reconciler probing the deployment URLs in
  order and using the first reachable one.
- Emissions are gated: a selected model with no configured backend deployment or
  a deployment with a missing instance produces assertions, not half-wired
  units. Runtimes with deployments must resolve to distinct cache directories.
- The catalog is the extension path for new backends (e.g. `vllm`/`sglang` via
  the `hf` field): add the reference field, then mirror the `backends.*` wiring.

## Fleet policy (pvl)

- `pvl-l5`: 7 models, four stopped deployments across two backends — `ollama`
  (11434, ROCm) and `ollama-nvidia` (12434, CUDA), started by hand for GPU
  sessions; `llama-router` (11000, ROCm) and `llama-router-nvidia` (12000, CUDA)
  the same way. Shared models dir `/var/lib/pvl/ollama-models`; shared GGUF
  cache `/var/lib/pvl/ai/llama-router`.
- `pvl-a1`: same 7 models; `ollama` (11434, auto), `ollama-nvidia` (12434,
  manual), and the same llama.cpp pair with the ROCm router auto-started
  (`llama-router`, 11000) and the CUDA router warmed by hand
  (`llama-router-nvidia`, 12000).
- `pvl-x2`: 14 models (full catalog minus `gemma4-12b`); `ollama` (11434, auto);
  keeps `qwen3.6:27b` retired. AMD-only host — no llama.cpp deployments.

## Migration deltas (evaluated against the pre-change baseline)

Unit sets, model lists, `models.ini` content, and container sources are
byte-identical after the migration. The intended diffs:

- Reconciler stamp keys normalize to deployment names (`ollama-nvidia`,
  `llama-router` instead of `ollamaNvidia`, `llamaRouter`), so each models
  dispatcher restarts once, idempotently.
- `pvl-x2`'s reconciler gains `ollamaUrls` and `reconcileTriggers` — the same
  shape `pvl-l5`/`pvl-a1` already had.
- `pvl-l5`'s llama-router cache moves to `/var/lib/pvl/ai/llama-router` (the
  module's canonical `${stack}/ai/llama-router` path). The container was never
  deployed, so no data moves; this converges on the abird convention.
- `pvl-l5`'s llama.cpp pair: the never-deployed CUDA instance on 11436 becomes
  `llama-router-nvidia` on 11437, and the default `llama-router` name on 11436
  now carries the AMD/ROCm image — the same primary/naming shape as the Ollama
  pair.
- `pvl-a1` gains the whole llama.cpp family: reconciler units and both container
  instances are new, so there is no migration churn; its ROCm router is the
  fleet's first auto-started llama.cpp deployment and its ready target orders
  the reconciler like the Ollama family.
- Option docs no longer describe the shared models dir as read-only: pulls run
  through the container API, so the mount is read-write by design.

The registry stays untouched: `data.services` is role-scoped (`services.x2`),
and mkApi consumers iterate it, so listing l5-hosted service ports there would
be misleading. Ports stay explicit per host in `ai.nix`.

## Stack storage ownership repair

The first `pvl-l5` llama-router start after the shared AI deployment failed
before container creation. The cache rule declared only
`/var/lib/pvl/ai/llama-router`; tmpfiles created the missing intermediate
`/var/lib/pvl/ai` as `root:root`, then rejected the transition from the
`pvl:pvl` stack root as unsafe. Later runs could neither correct the parent nor
create the cache leaf, so Podman returned status 125 while resolving the bind
source.

The common Pvl host profile now owns `/var/lib/pvl` once for `pvl-a1`, `pvl-l5`,
and `pvl-x2`, ordered before service-specific rules. The AI module owns the `ai`
parent and its configured backend leaves with the deployment user's ownership.
Together they emit the complete stack root, `ai` parent, and cache leaf
hierarchy without duplicate ownership declarations. An explicit custom cache
path receives only its leaf rule; the module does not take ownership of an
operator-selected mount hierarchy. Reapplying tmpfiles corrects an existing
root-owned `ai` parent and creates the missing leaf in the same run.
