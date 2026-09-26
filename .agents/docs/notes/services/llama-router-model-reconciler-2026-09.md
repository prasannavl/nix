# Llama.cpp Router Model Reconciler, 2026-09

## Decision

`pvl-l5` runs llama.cpp's router mode as a Podman Compose device-class set next
to the Ollama set: CPU `llama-cpu` (`11000`), ROCm `llama-rocm` (`12000`), and
NVIDIA `llama-nvidia` (`13000`), all sharing one GGUF cache and one reconciler.
The current port and naming scheme is device-class first; see
`.agents/docs/notes/hosts/pvl-ai-backend-port-convention-2026-09.md`.
Declarative model reconciliation uses
`lib/services/llama-router.mkModelReconciler`, which mirrors the shared Ollama
reconciler: a retained dispatcher attached to `pvl-managed.target` and an
asynchronous `pvl-llama-router-models-load.service` worker with a 3600-second
start timeout, `ConditionUser pvl`, backend `After=` (never `Wants=`) ordering,
and the skip-if-all-backends-inactive API wait.

The same model set as Ollama is expressed as Hugging Face references
(`org/repo:quant`), and the lib single-sources it: the worker's `ExecStart`
model arguments and the router's staged `models.ini` are both derived from
`requiredModels`, so the preset cannot drift from the reconciler policy.

Each catalog backend value accepts a reference string as the minimal form or an
expanded attrset with `ref` plus backend configuration. The projector normalizes
both forms immediately. Chat models use the expanded `llama` form with
`preset.jinja = true`, which flows into `models.ini` so llama.cpp uses each
model's embedded Jinja chat template; the embedding model keeps the string form
and deliberately omits it. The derived `alias`, `hf`, and `embeddings` keys are
protected from preset overrides. This does not add external template files or
generate any Codex, Pi, or OpenCode client configuration.

## Upstream semantics (verified at image revision b29c606e)

- Router mode is `llama-server` without a model, driven by
  `--models-preset /etc/llama-router/models.ini`; the container command only
  supplies that flag, everything else stays at llama.cpp defaults
  (`--models-autoload` on, `--models-max` 4 with LRU eviction, ctx 4096, flash
  attention auto).
- Preset section names use the full `org/repo:tag` reference so they merge with
  cache-scanned entries, and `hf = <ref>` makes each section resolvable before
  the first download. Per-model `alias` keys preserve Ollama-style short names
  (`qwen3.5:4b`) for clients, and `embeddings = true` marks the dedicated
  embedding model.
- `GET /models` reports per-model `status.value`
  (`unloaded|loading|loaded|sleeping`) plus `failed`/`exit_code`; there is no
  "downloading" state, so a child that dies mid-download also appears as
  `failed`. `POST /models/load`/`models/unload` answer `{"success":true}`.
- Children download `hf` refs into `LLAMA_CACHE` in the Hugging Face hub layout
  (`models--org--repo/{blobs,snapshots}`), which the host binds from
  `/var/lib/pvl/ai/llama-router`.

## Deltas from the Ollama reconciler

- No `try-restart` after changes: loads and unloads are live API operations, and
  `GET /models?reload=1` (after pruning) refreshes the router's cache view;
  restarting the router would unload every model.
- Retirement is two-phase because the router has no cache-deletion API: unload
  the model first, then remove `models--org--repo` from the host cache. The
  helper validates reference shapes before any `rm -rf`.
- The worker unloads retired models before loading required ones so retirement
  frees VRAM first, then loads required models sequentially.
- A failed load with cached snapshot weights logs a warning instead of failing
  the reconcile (the `pvl-l5` 6 GB GPU may refuse the 9B model), while a failed
  load without cached weights hard-fails because the download itself failed.
- A required model absent from `GET /models` is a hard failure: with the
  lib-sourced preset it means configuration drift, not a missing download.
- `cacheDir` is mandatory (retirement pruning and the failure diagnostics read
  the HF cache layout directly) and the helper never uses `find` or `awk`,
  preserving the ollama helper's minimal runtime-input contract.

## Idle-power policy: load-lazy reconcile (2026-09-19)

Measured on `pvl-a1` (AMD iGPU, ROCm image): the first deployed generation
loaded every required model at each dispatch, and with `--models-max` 4 that
left four resident workers on the APU with the GPU pinned at idle - `gpu_busy`
100%, SCLK 2900 MHz, 17-19 W, 26 GiB of GTT - until the service was stopped
(100% -> 5%, 655 MHz instantly at teardown). The burn is a step function of
resident worker count, not of traffic: one resident model idles at 20-24% busy /
~900 MHz / ~7 W, two resident models pin 96-100% / 2900 MHz. That step was
measured with the server's default `poll` 50 busy-poll active on each worker, so
the context-count share of it is not separated out; re-measure two residents
under the `poll = "0"` presets after deploy.

Non-causes verified against the pinned llama.cpp source and the live router:

- The server never eager-loads with our preset: the "loaded on-demand" banner is
  literal, and the first generation's startup load burst was the reconcile
  worker itself (`unloaded` -> force `POST /models/load`), matching every spawn
  timestamp to the second.
- Cache-scanned presets carry no `load-on-startup`; the merged presets served by
  `GET /models` are a mirror of our own ini. No override keys are needed.
- `--no-models-autoload` is not a lazy switch: at this revision it makes
  `router_validate_model` reject requests for models that are not already
  running (clients can opt back in per request with `?autoload=true`). The
  flag's default (on) is exactly the on-demand behavior we want.

Policy, in force since:

- Reconcile is download-verify, not load-ensure: an `unloaded` or `failed`
  required model with cached weights is left to its first request; only models
  with missing weights are load-requested (the download path) - with the
  resource-limit recovery semantics unchanged.
- Every generated preset sets `poll = "0"`: the server default of 50 busy-polls
  the backend while waiting for work.
- The laptop variants (`pvl-a1`, `pvl-l5`) pass `--models-max 3` so the
  embedding model stays co-resident with up to two chat models (a router-side
  `/embeddings` request no longer LRU-evicts a chat worker); a fourth
  distinct-model request still goes through LRU eviction. `abird-srv` keeps the
  upstream default of 4.

Trade-off: with idle sleep disabled a resident model holds memory until a
different-model request evicts it via LRU, and the first request after boot pays
the load (seconds, like Ollama cold). With `--models-max 3` the common steady
state is embedding + one or two chat models resident, so the multi-resident idle
cost under `poll = "0"` should be verified after deploy; the original complaint
scenario (all required models force-loaded at boot) cannot recur with the lazy
reconcile.

## Idle sleep: keep_alive parity (2026-09-22)

Correction to the trade-off above: the pinned image
(`server-{rocm,cuda}-v0.4.1`, revision `b29c606e`) **does** ship an idle TTL.
`llama-server` accepts `--sleep-idle-seconds SECONDS` (default `-1` = disabled);
after that many seconds without an incoming task the child worker calls
`destroy()`, dropping the model weights and KV cache (including GPU memory)
while keeping the model listed as `sleeping`, and the next request reloads it on
demand. This is the Ollama `keep_alive` equivalent the earlier section said was
missing.

Two upstream facts make it wire cleanly into the reconciler:

- `server-models.cpp::unset_reserved_args` strips only router-owned keys
  (host/port/api-key/models-dir/models-max/models-preset/models-autoload, plus
  model identity) before spawning a child; `--sleep-idle-seconds` is left
  intact, so the router's own flag would be inherited by every child via
  `base_preset`.
- `load_from_ini` stores the `[*]` section as the global preset and
  `load_models()` cascades it onto cached, `--models-dir`, and custom presets
  before overlaying router CLI args. A `[*]` key therefore applies to every
  model, including cache-scanned ad-hoc entries.

The module uses the second path:
`services.ai.backends.llamaRouter.deployments[*].idleTimeoutSeconds` inherits
from `llamaRouter.defaults` and is emitted as `[*] sleep-idle-seconds = <n>` in
that service's generated `models.ini`; `false` disables an inherited value.
`pvl-a1` and `pvl-l5` set `300` seconds, matching Ollama's default keep-alive,
so a large model no longer stays resident behind a follow-up request; it sleeps
after the idle window and the next request reloads it. `--models-max 3` allows
embedding plus up to two chat models to co-reside while active, but idle workers
release memory instead of waiting for a fourth-model LRU eviction.

Validated on `pvl-l5`: the generated `models.ini` renders the `[*]` section, the
rendered host config evaluates with `idleTimeoutSeconds = 300`, and a one-off
`server-rocm-v0.4.1` container loaded the generated preset with no "option not
recognized" error (`Loaded 7 custom model presets`). The `lib-ai-module` and
`lib-llama-router-module` checks pass.

## VRAM-aware `models-max` is not supported (2026-09-22)

Follow-up question: can `--models-max` apply only when GPU VRAM is exhausted,
loading as many models as fit instead of a fixed count? Not with upstream
llama.cpp. The router scheduler (`server_lru_sched` in `server-models.cpp`) is
purely count-based: `has_capacity()` is
`models_max <= 0 || count_running() <
models_max`, `pick_victim()` returns the
least-recently-used ready-or-sleeping model, and no scheduler path queries
device free/total memory. The same code on upstream `master` is unchanged, so
bumping the image would not add it.

Relevant knobs at this revision:

- `--models-max 0` = unlimited count. `tick()` then returns early, so the router
  performs **no** LRU eviction at all; a model that cannot fit is not made room
  for.
- `--fit on` (default), `--fit-target MiB`, `--fit-ctx N`: load-time adjustment
  of _unset_ args (`n-gpu-layers`, `ctx`) so a single model fits currently free
  device memory. This uses whatever VRAM is free, but the fallback is partial/
  CPU offload, not evicting a resident model. Setting `n-gpu-layers` explicitly
  disables fit for that model.
- `--sleep-idle-seconds` (previous section): idle release.

So the closest native approximation to "load until VRAM is full, evict only
then" is `--models-max 0` + default `--fit on` + `--sleep-idle-seconds N`:
models keep loading and each fits the remaining VRAM, but excess models degrade
to CPU offload instead of evicting an idle GPU-resident model, and resident
count (and system-RAM use) can grow until idle sleep reclaims it. A true
memory-aware LRU would need either an upstream scheduler change or an external
controller that polls free VRAM (`rocm-smi`/`nvidia-smi`) and calls
`POST /models/unload` for the LRU idle model before the next load. That API does
not guard against busy models, so such a controller must track `req_count`/
status itself. `--models-max 3` plus idle sleep is the adopted middle ground:
more concurrency with bounded LRU eviction, and idle sleep bounds the resident
set in time.

## Host mapping

`pvl-l5` has no readiness target; the reconciler observes
`pvl-llama-router.service` and `pvl-llama-router-nvidia.service`, probing
`http://127.0.0.1:11000` and `http://127.0.0.1:12000`. A manually started router
therefore reconciles while the declaratively stopped state skips cleanly without
starting either backend. The cache directory is a host tmpfiles rule
(`/var/lib/pvl/ai/llama-router`, `0755 pvl pvl`) like the shared Ollama models
directory, and the staged `models.ini` is a bind-mounted recreate-class file, so
model-list changes recreate the container and re-trigger the dispatcher via the
instance config hash.

Open WebUI still points only at the two Ollama ports; wiring it to the llama.cpp
router endpoints is a deliberate follow-up, not part of this change.

The same `lib/services/llama-router` also binds on the Abird upstream stack:
`abird-srv` derives its model list from the shared `modelCatalog` (`llama` GGUF
fields, `alias` presets mapping back to the catalog IDs), serves registry port
11436, and runs the ROCm image variant of the same v0.4.1 release. The binding
is recorded in the Abird note
`.agents/docs/notes/hosts/abird-llama-router-2026-09.md`; the shared library is
kept byte-identical across both repos, like `lib/services/ollama`.

## Validation

The shared helper and module checks pass (fake curl/systemctl/sleep binaries
with a failing `awk` on `PATH`), including cache-presence failure semantics,
retirement prune plus reload, and skip-when-stopped behavior. The `pvl-l5` NixOS
toplevel builds, and rendered-unit inspection confirms the dispatcher
`X-Restart-Triggers`, worker `After=` ordering without `Wants=`, the staged
preset INI, port mappings `11000:8080` and `12000:8080`, and the NVIDIA
reservation block mirroring `ollama-nvidia`.

The service is built but not deployed; the instance stays declaratively stopped
until it is activated manually.
