# Llama.cpp Router Model Reconciler, 2026-09

## Decision

`pvl-l5` runs llama.cpp's router mode
(`ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1`) as a third Podman Compose
backend next to the Ollama pair, published on host port `11436`. Declarative
model reconciliation uses `lib/services/llama-router.mkModelReconciler`, which
mirrors the shared Ollama reconciler: a retained dispatcher attached to
`pvl-managed.target` and an asynchronous `pvl-llama-router-models-load.service`
worker with a 3600-second start timeout, `ConditionUser pvl`, backend `After=`
(never `Wants=`) ordering, and the skip-if-all-backends-inactive API wait.

The same model set as Ollama is expressed as Hugging Face references
(`org/repo:quant`), and the lib single-sources it: the worker's `ExecStart`
model arguments and the router's staged `models.ini` are both derived from
`requiredModels`, so the preset cannot drift from the reconciler policy.

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
~900 MHz / ~7 W, two resident models pin 96-100% / 2900 MHz. Two or more
concurrent ROCm contexts defeat amdgpu clock gating; it is a driver-level
effect, independent of workload.

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
- The laptop variants (`pvl-a1`, `pvl-l5`) pass `--models-max 1` so concurrent
  requests cannot stack resident contexts; swapping models goes through LRU
  eviction. `abird-srv` keeps the upstream default of 4.

Trade-off: this llama.cpp revision has no idle TTL (no Ollama `keep_alive`
equivalent), so a resident model holds memory until the next different-model
request evicts it, and at `--models-max 1` a router-side `/embeddings` request
swaps out the resident chat model. Embeddings are served by the Ollama pair
today, and the first request after boot pays the load (seconds, like Ollama
cold).

## Host mapping

`pvl-l5` has no readiness target; the reconciler observes
`pvl-llama-router.service` and probes `http://127.0.0.1:11436`, so a manually
started router reconciles while the declaratively stopped state skips cleanly
without starting the backend. The cache directory is a host tmpfiles rule
(`/var/lib/pvl/llama-router/cache`, `0755 pvl pvl`) like the shared Ollama
models directory, and the staged `models.ini` is a bind-mounted recreate-class
file, so model-list changes recreate the container and re-trigger the dispatcher
via the instance config hash.

Open WebUI still points only at the two Ollama ports; wiring it to
`http://127.0.0.1:11436` is a deliberate follow-up, not part of this change.

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
preset INI, port `11436:8080`, and the NVIDIA reservation block mirroring
`ollama-nvidia`.

The service is built but not deployed; the instance stays declaratively stopped
until it is activated manually.
