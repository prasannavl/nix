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
  per-backend `deployments` (name, port, lifecycle). llama.cpp deployments also
  select runtime, cache, model placement, and idle policy, with shared backend
  defaults.
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

- `services.ai.models` is the host admission list of catalog keys; null selects
  every model with an Ollama or llama.cpp deployment, while an explicit list may
  also admit an HF-backed model for a host-owned vLLM/SGLang service. Unknown
  keys fail evaluation.
- `roles` are keys into the same selection; roles pointing outside the selection
  fail evaluation (null defaults, hosts opt in).
- Catalog admission is fleet-wide. A malformed unselected entry fails the policy
  rather than remaining latent until a future host selects it.
- A backend activates only when its `deployments` list is non-empty. Catalog
  references record capability; configured membership requires a valid reference
  and a deployment, plus a compatible runtime for llama.cpp. Catalog
  `llama.runtimes` lists compatible engines, and deployment `models` only
  narrows placement beneath host admission. Each deployment must have a matching
  host-declared `podman-compose` instance (the module asserts `source != null`);
  the module never declares compose sources.
- Pulls run through the running backend's API, so the shared Ollama models dir
  (and the llama.cpp cache dir) are mounted read-write into the containers;
  whichever deployment performs a pull, blobs land once in the shared location
  and every deployment serves them.
- Backends take multiple deployments sharing one storage location: the dual-GPU
  hosts run an AMD and an NVIDIA variant side by side (mirroring
  `ollama`/`ollama-nvidia`), with the reconciler probing the deployment URLs in
  order and using the first reachable one.
- Emissions are gated: a selected model with neither configured backend
  membership nor an explicit HF source, or a deployment with a missing instance,
  produces assertions rather than half-wired units. Runtimes with deployments
  must resolve to distinct canonical cache directories.
- The catalog is the extension path for new backends (e.g. `vllm`/`sglang` via
  the `hf` field): add the reference field, then mirror the `backends.*` wiring.

## Fleet policy (pvl)

Device-class port scheme (current, 2026-09-22): CPU/Vulkan `11xxx`, ROCm
`12xxx`, NVIDIA `13xxx`, with llama.cpp PrismML one slot higher. See
`.agents/docs/notes/hosts/pvl-ai-backend-port-convention-2026-09.md`.

- `pvl-l5`: 8 models (the a1 set plus ternary `bonsai2-27b`). Ollama
  `ollama-cpu` (11434, manual), `ollama-rocm` (12434, stopped), `ollama-nvidia`
  (13434, stopped); llama.cpp `llama-cpu` (11000, manual), `llama-rocm` (12000,
  stopped), `llama-nvidia` (13000, stopped); PrismML `llama-prism-rocm` (12001,
  stopped), `llama-prism-nvidia` (13001, stopped). Shared models dir
  `/var/lib/pvl/ollama-models`; shared GGUF caches
  `/var/lib/pvl/ai/llama-router` and `/var/lib/pvl/ai/llama-router-prism`.
- `pvl-a1`: 8 models (the same set). Ollama `ollama-cpu` (11434, manual),
  `ollama-rocm` (12434, auto), `ollama-nvidia` (13434, manual); llama.cpp
  `llama-cpu` (11000, manual), `llama-rocm` (12000, auto), `llama-nvidia`
  (13000, manual); PrismML `llama-prism-rocm` (12001, auto),
  `llama-prism-nvidia` (13001, manual).
- `pvl-x2`: 14 models (full catalog minus `gemma4-12b`; `qwen36-35b-a3b` retired
  fleet-wide 2026-09-23). Ollama `ollama-rocm` (12434, auto, the primary backing
  Open WebUI) and `ollama-cpu` (Vulkan, 11434, manual fallback); llama.cpp
  `llama-rocm` (12000, manual) and `llama-cpu` (11000, manual), PrismML
  `llama-prism-rocm` (12001, manual). AMD-only, so no NVIDIA class and no
  `llama-nvidia`/`llama-prism-nvidia`.

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

## Model retirement: `qwen36-35b-a3b`

2026-09-23: `qwen36-35b-a3b` (`qwen3.6:35b-a3b`) is retired fleet-wide. It was
selected only by `pvl-x2`. The catalog entry and the `pvl-x2` selection are
removed; the shared Ollama reconciler's `retire_unrequired_owned_models` deletes
any owned-but-unrequired model on the next reconcile, so no separate
`retiredModels` list is needed.

Retirement context: the 2026-09-23 dirty-staged `pvl-x2` deploy stalled pulling
this tag and the reconcile worker hit its own 1-hour `TimeoutStart`, so the pull
never completed and the model was never registered as an owned model. An orphan
`sha256-d372de8e…-partial` blob (~21 GB, plus 22 chunk sidecars) was left in
`/var/lib/pvl/ollama-models/blobs/` on `pvl-x2`; the reconciler would not remove
it because it is not an owned model. It was deleted manually on 2026-09-23
(models store 101 G → 82 G; no installed manifest referenced the digest).
