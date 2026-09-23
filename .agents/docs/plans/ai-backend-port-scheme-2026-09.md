# AI Backend Device-Class Port Scheme, CPU Deployment, and vLLM/SGLang Reservations

## Status

Implemented on 2026-09-22 in the main worktree as a host-plane change only (no
`lib/services/ai` change). The current port, naming, lifecycle, and client
profile convention lives in
`.agents/docs/notes/hosts/pvl-ai-backend-port-convention-2026-09.md`; this file
stays as the design record, including the reserved vLLM/SGLang blocks and the
remaining open questions. Fleet scope was later extended so `pvl-l5` also runs
the PrismML fork set and `pvl-x2` runs the AMD-capable llama.cpp set.

## Summary

This plan establishes one port and naming scheme for the Pvl AI backends
(`pvl-a1`, `pvl-l5`), adds the missing CPU/Vulkan device class for llama.cpp and
Ollama, renames the llama.cpp instances to explicit device-class names, aligns
Ollama to the device-class blocks, and reserves ports for vLLM and SGLang even
though neither is deployed today.

Device classes are ordered **CPU, ROCm, NVIDIA**, with the device class owning
the port's thousands block and the backend owning a hundreds block:

- CPU `11xxx`, ROCm `12xxx`, NVIDIA `13xxx`.
- llama.cpp `+000`, vLLM `+100`, SGLang `+200`, future/aligned backends `+300`
  and up.

Immediate concrete result: llama.cpp default runtime is CPU `11000`, ROCm
`12000`, NVIDIA `13000`; the PrismML runtime is `11001`, `12001`, `13001`; and
Ollama is CPU+Vulkan `11434`, ROCm `12434`, NVIDIA `13434`. This replaces the
current implicit order (llama.cpp ROCm `11000`, NVIDIA `12000`, prism
`11001`/`12001`; Ollama ROCm `11434`, NVIDIA `12434`).

The current phase is host-plane only. `lib/services/ai` already accepts an
arbitrary deployment list sharing one cache and reconcile cycle, so the CPU
deployment, renumber, and rename need no shared-library change. vLLM and SGLang
are reserved in the port registry and described as a later lib + host phase.

The renumber and rename are breaking changes for live ports, mutable client
configuration, and systemd unit names, so the plan includes an explicit
migration/rollout section.

## Current Baseline

Per host, `hosts/<host>/services/llama-router.nix` declares container
definitions and `hosts/<host>/services/ai.nix` declares deployments and
lifecycle. Ports are derived from each instance's `exposedPorts.main.port`.

| Host     | Runtime | Device | Instance                    | Port    | Lifecycle |
| -------- | ------- | ------ | --------------------------- | ------- | --------- |
| `pvl-a1` | default | ROCm   | `llama-router`              | `11000` | `auto`    |
| `pvl-a1` | default | NVIDIA | `llama-router-nvidia`       | `12000` | `manual`  |
| `pvl-a1` | prism   | ROCm   | `llama-router-prism`        | `11001` | `auto`    |
| `pvl-a1` | prism   | NVIDIA | `llama-router-prism-nvidia` | `12001` | `manual`  |
| `pvl-l5` | default | ROCm   | `llama-router`              | `11000` | `stopped` |
| `pvl-l5` | default | NVIDIA | `llama-router-nvidia`       | `12000` | `stopped` |

Ollama currently runs ROCm `11434` and NVIDIA `12434` (no CPU/Vulkan
deployment). The target scheme aligns it to CPU+Vulkan `11434`, ROCm `12434`,
NVIDIA `13434`. The current convention is documented in
`.agents/docs/notes/hosts/pvl-ai-backend-port-convention-2026-09.md`, which
becomes historical on implementation.

Both deployments of a llama.cpp runtime share one GGUF cache
(`/var/lib/pvl/ai/llama-router`), one `models.ini`, one reconciler state file,
and one reconciler unit pair. The reconciler probes deployment URLs in order and
uses the first reachable API; the ready target comes from the first `auto`
deployment.

## Port Scheme

### Device-class blocks

| Device     | Role                                                         | Block   |
| ---------- | ------------------------------------------------------------ | ------- |
| CPU/Vulkan | CPU, plus Vulkan where the engine supports it (Ollama image) | `11xxx` |
| ROCm       | AMD GPU, device-exclusive                                    | `12xxx` |
| NVIDIA     | NVIDIA GPU, device-exclusive                                 | `13xxx` |

### Backend blocks and slot

`port = deviceBase + backendBlock + slot`

- `deviceBase`: CPU `11000`, ROCm `12000`, NVIDIA `13000`.
- `backendBlock`: llama.cpp `0`, vLLM `100`, SGLang `200`, future backends
  `+100`. Ollama is the documented exception below (`deviceBase + 434`).
- `slot`: `0`-`99` within a backend block. llama.cpp runtimes use `0`
  (`default`) and `1` (`prism`); vLLM and SGLang use one slot per served model
  or worker, because both are single-model servers (see D8).

### Reserved and assigned ports

| Backend   | Slot meaning     | CPU             | ROCm            | NVIDIA          |
| --------- | ---------------- | --------------- | --------------- | --------------- |
| llama.cpp | `0` default      | `11000`         | `12000`         | `13000`         |
| llama.cpp | `1` prism        | `11001`         | `12001`         | `13001`         |
| vLLM      | per model/worker | `11100`-`11199` | `12100`-`12199` | `13100`-`13199` |
| SGLang    | per model/worker | `11200`-`11299` | `12200`-`12299` | `13200`-`13299` |
| Ollama    | device class     | `11434`         | `12434`         | `13434`         |

llama.cpp, vLLM, and SGLang share `11000`, `12000`, `13000` as their block
starts; a port is only ever assigned to one backend because slots do not overlap
between blocks. `11000`/`12000`/`13000` are unused by any other host service.

Ollama keeps its well-known `434` suffix and maps the device class to the
thousands digit (`port = deviceBase + 434`): CPU+Vulkan `11434`, ROCm `12434`,
NVIDIA `13434`. This keeps the public `11434` identity while staying
device-class aligned.

## Instance Naming

llama.cpp is the engine family name; instances are `llama-<device>` for the
default runtime and `llama-prism-<device>` for the PrismML runtime. The bare
`llama-router` name is dropped: "router" is a llama.cpp mode, not an identity,
and it collides conceptually with the multiple device-class deployments.

| Backend   | Default / runtime    | CPU (reserved where n/a) | ROCm               | NVIDIA               |
| --------- | -------------------- | ------------------------ | ------------------ | -------------------- |
| llama.cpp | default              | `llama-cpu`              | `llama-rocm`       | `llama-nvidia`       |
| llama.cpp | prism                | `llama-prism-cpu`        | `llama-prism-rocm` | `llama-prism-nvidia` |
| Ollama    | default (CPU+Vulkan) | `ollama-cpu`             | `ollama-rocm`      | `ollama-nvidia`      |
| vLLM      | default              | `vllm-cpu`               | `vllm-rocm`        | `vllm-nvidia`        |
| SGLang    | default              | `sglang-cpu`             | `sglang-rocm`      | `sglang-nvidia`      |

`vllm-*` and `sglang-*` names are reserved by this plan; they are not declared
in any host file yet. Container `container_name` and the instance attribute use
the same name. The compose service key inside each instance's source is
instance-local (each instance is its own compose project), so keep it equal to
the instance name for legibility.

`services.ai.backends.llamaRouter` keeps its option name: it is the llama.cpp
router-mode backend, and the engine is `llama.cpp`. Only the per-host instance
names change.

## Design Decisions

### D1: CPU is a third deployment of the `default` runtime

`runtime` means engine/build identity (upstream llama.cpp vs the PrismML fork):
it owns a cache directory, a reconciler, and a `models.ini`. Device class is a
deployment concern. CPU serves the same GGUF set as ROCm and NVIDIA, so it joins
`runtimes.default.deployments`. A separate `cpu` runtime would force a distinct
cache directory (asserted unique across runtimes with deployments), duplicate
every multi-GB download, and add a second reconciler and state file.

Consequence: `models.ini`, `preservedModels`, `idleTimeoutSeconds`, and the
reconciler unit names are unchanged.

### D2: CPU deployment uses the stock CPU image at the shared release

Image: `ghcr.io/ggml-org/llama.cpp:server-v0.4.1` (verified present on GHCR,
same release as `server-rocm-v0.4.1` / `server-cuda-v0.4.1`).

The CPU image has no GPU backend, so isolation is inherent: no `/dev/kfd`, no
`/dev/dri`, no `deploy.resources.reservations`, no `keep-groups`. Do not reuse a
GPU image with devices removed; the GPU images assume accelerator userspace.

All llama.cpp tags must move as one release so shared `models.ini` presets and
GGUF compatibility cannot drift across device classes.

### D3: CPU lifecycle is `manual` on both hosts

Confirmed decision: `llama-cpu` is `manual` on `pvl-a1` and `pvl-l5` (never
auto-started, survives if started by hand). Existing ROCm/NVIDIA lifecycles are
unchanged:

- `pvl-a1`: ROCm `auto`, NVIDIA `manual`, CPU `manual`.
- `pvl-l5`: ROCm `stopped`, NVIDIA `stopped`, CPU `manual`.

### D4: CPU worker uses `--models-max=2`

Confirmed decision: the CPU deployment runs
`--models-preset /etc/llama-router/models.ini --models-max 2`.

Two resident workers cover the embedding model plus one chat model; the GPU
variants keep `--models-max 3`. Threads, context size, and other knobs stay at
upstream defaults for the first rollout
(`.agents/docs/design-patterns/prefer-defaults.md`); add
`--threads`/`--ctx-size` only after measuring.

Keep `serviceOverrides.serviceConfig.TimeoutStartSec = "10min"` for cold image
pull, and keep `LLAMA_CACHE=/cache` with the shared cache bind.

The `models.ini` mount path stays `/etc/llama-router/models.ini`: it is the
router-mode preset path, not an instance name, and changing it would churn every
deployment for no benefit.

### D5: Renumber and rename existing deployments

Confirmed decisions: ports move to the device-class scheme, and instances rename
to `llama-<device>` / `llama-prism-<device>`.

Port moves:

| Instance (old)              | Port (old) | Instance (new)       | Port (new) |
| --------------------------- | ---------- | -------------------- | ---------- |
| `llama-router`              | `11000`    | `llama-rocm`         | `12000`    |
| `llama-router-nvidia`       | `12000`    | `llama-nvidia`       | `13000`    |
| `llama-router-prism`        | `11001`    | `llama-prism-rocm`   | `12001`    |
| `llama-router-prism-nvidia` | `12001`    | `llama-prism-nvidia` | `13001`    |
| (new)                       | -          | `llama-cpu`          | `11000`    |

The new map does not assign an old port to a different simultaneously running
device class on the same host; migration stops the old manual GPU containers
first (see Migration).

### D6: No shared-library change in this phase

Verified against `lib/services/ai/module.nix`:

- `llamaRuntimeType.deployments` accepts any-length lists.
- Cache uniqueness is enforced across runtimes, not across deployments of one
  runtime.
- Deployment instance names, resolved service names, and API ports are asserted
  globally unique; the new names and ports satisfy this.
- `runtimesInfo.default.*` picks up a third entry and renumbers from
  `exposedPorts`.
- The AI module stages `files."models.ini"` into every deployment of an active
  runtime, so the CPU container receives the preset file with no extra wiring.

`lib/services/ai`'s `defaultInstanceName.llamaRouter = "llama-router"` fallback
simply stops matching host declarations; hosts pin `instance` explicitly, so no
lib edit is needed.

Expected diffs: `hosts/pvl-a1/services/llama-router.nix`,
`hosts/pvl-a1/services/ai.nix`, `hosts/pvl-l5/services/llama-router.nix`,
`hosts/pvl-l5/services/ai.nix`, plus docs. `lib/` stays untouched.

### D7: Ollama aligns to the device-class blocks and gains CPU+Vulkan

Confirmed mapping: CPU+Vulkan `11434`, ROCm `12434`, NVIDIA `13434`, with
instances `ollama-cpu` / `ollama-rocm` / `ollama-nvidia`. The `434` suffix keeps
the public `11434` identity in the CPU block while ROCm and NVIDIA take their
device-class thousands digit.

The CPU+Vulkan deployment uses the default `docker.io/ollama/ollama:<tag>` image
with `OLLAMA_VULKAN=1` and the shared Ollama models dir. It mounts `/dev/dri`
for the Vulkan render node, but no `/dev/kfd` (that is the ROCm path) and no
NVIDIA CDI reservation. Lifecycle is `manual` on `pvl-a1` and `pvl-l5`, matching
`llama-cpu`.

Migration on a1/l5: `ollama` (ROCm) `11434`→`12434`, `ollama-nvidia`
`12434`→`13434`, and a new `ollama-cpu` at `11434`. Mutable Ollama profiles
(`local-cpu`, `local-rocm`, `local-nv`) and Open WebUI's derived
`OLLAMA_BASE_URLS` move with them.

`pvl-x2` is AMD-only and gets both non-NVIDIA classes: `ollama-rocm` at `12434`
is the primary/auto deployment and the Open WebUI backend, while `ollama-cpu`
(CPU + Vulkan) at `11434` is the manual fallback. The `x2` client provider stays
on `11434` (on-demand fallback) and `x2-rocm` points at `12434`. The service
registry `ollama` port stays `11434` (the default/Vulkan endpoint).

### D8: vLLM and SGLang are reserved now, integrated later

Neither is deployed today. Their ports and names are reserved so a later
implementation does not renumber llama.cpp again. Their serving model differs
from llama.cpp and constrains the integration design:

- llama.cpp router mode serves many models from one process (`--models-preset`,
  `--models-max`), so one deployment per device class covers the whole
  selection.
- vLLM and SGLang serve one model per process by default (vLLM with tensor
  parallelism for multi-GPU; SGLang with data-parallel workers). Neither has a
  native multi-model server like llama.cpp router mode or Ollama: multi-model
  service needs N worker processes plus a separate routing layer. A device-class
  endpoint is therefore per model or per worker, not per whole selection.

Integration boundaries for the later phase:

- **Catalog.** Add explicit `vllm` and `sglang` reference fields (string or
  `{ref, ...}` attrset), mirroring `ollama` and `llama`, so membership and
  duplicate checks stay backend-explicit. `hf` remains the canonical HF repo for
  `catalogById`/Web UI consumers.
- **Backends.** Add `services.ai.backends.vllm.deployments` and
  `services.ai.backends.sglang.deployments`, reusing `deploymentType`. Because
  each deployment serves one model, extend the deployment shape with the served
  catalog key (for example `model = "qwen35-4b"`). Ports come from the reserved
  block, one slot per served model.
- **Routing layer.** Neither backend has llama.cpp router mode built into the
  server. Multi-model or multi-replica service uses a separate router/proxy:
  vLLM Production Stack's router (model-aware routing plus KV/cache-aware load
  balancing across vLLM backends), SGLang's `sglang_router` (cache-aware load
  balancing across SGLang workers, with multi-model worker-group routing in
  newer releases), or a generic OpenAI-compatible gateway such as LiteLLM. vLLM
  also serves multiple LoRA adapters as named models from one process
  (`--enable-lora --lora-modules`), but not multiple base models. If a gateway
  is used, only the gateway publishes a host port (slot `0` of the backend
  block); worker replicas stay on the internal compose network and need no
  reserved host ports. Start with direct per-model deployments and add a gateway
  only if fan-out or model count demands it.
- **Acquisition and ownership.** vLLM/SGLang download from HF at server start
  into `HF_HOME`/`--download-dir`; there is no cache-only download API like
  llama.cpp's `POST /models`. The existing Ollama/llama reconciler does not map
  directly. Proposed v1: one shared HF cache (`/var/lib/pvl/ai/hf`, mounted
  read-write by vLLM and SGLang) with acquisition-on-demand and **no deletion
  authority**; add an ownership manifest only if a pre-pull helper
  (`hf download <repo> --revision <rev>`) is introduced, and never delete HF
  cache repos from inventory scans.
- **Health/readiness.** vLLM `GET /health`; SGLang `GET /health` or
  `GET /v1/models`. The podman-compose module already generates a local HTTP
  probe for instances exposing an `http` port, which covers first-pass
  readiness; a generic API reconciler helper is a later addition.
- **Images and devices.** CUDA (NVIDIA) and ROCm are the supported classes for
  both; the CPU classes (`vllm-cpu`/`sglang-cpu`) are reserved in the port
  registry but intentionally skipped — no vLLM/SGLang CPU deployment is planned,
  and neither has a Vulkan backend. Images: vLLM `vllm/vllm-openai:<tag>`
  (NVIDIA) and `vllm/vllm-openai-rocm:<tag>` (ROCm); SGLang
  `lmsysorg/sglang:<tag>` (NVIDIA) and its ROCm images where published. Device
  mapping is identical to llama.cpp: ROCm `/dev/kfd` + `/dev/dri`, NVIDIA CDI
  reservation. Pin image tags and let the Podman image updater track them.
- **Consumers.** Both expose OpenAI-compatible `/v1`, so Open WebUI can add
  `OPENAI_API_BASE_URLS` later; `catalogById` already produces the id→hf map.
- **Lib scope.** Adding backends is a `lib/services/ai` change shared with
  abird: `backends.nix`, `projection.nix` (`resolvePolicy` membership,
  diagnostics, roles, projections), `module.nix` (options, projections,
  lifecycle wiring), plus tests. Treat it as a separate phase, not part of the
  CPU/renumber/rename change.

## Concrete Change List (current phase)

For each of `hosts/pvl-a1/services/llama-router.nix` and
`hosts/pvl-l5/services/llama-router.nix`:

1. Rename instances and `container_name` per D5, and set
   `exposedPorts.main.port` per the target map.
2. Add the CPU instance, following
   `.agents/docs/design-patterns/podman-compose-instance.md` ordering:

```nix
llama-cpu = rec {
  exposedPorts.main.port = 11000;

  source = ''
    services:
      llama-cpu:
        image: ghcr.io/ggml-org/llama.cpp:server-v0.4.1
        container_name: llama-cpu
        command:
          - --models-preset
          - /etc/llama-router/models.ini
          - --models-max
          - "2"
        ports:
          - "${toString exposedPorts.main.port}:8080"
        volumes:
          - ./models.ini:/etc/llama-router/models.ini:ro
          - <defaultCache>:/cache
        environment:
          - LLAMA_CACHE=/cache
  '';

  serviceOverrides.serviceConfig.TimeoutStartSec = "10min";
};
```

`pvl-a1` threads `defaultCache` and `prismCache` lets; the CPU instance uses
`defaultCache`. `pvl-l5` threads a single `cacheDir` let.

Then update the host policy:

- `hosts/pvl-a1/services/ai.nix`: rename the default-runtime deployment
  instances to `llama-rocm` / `llama-nvidia`, add
  `{ instance = "llama-cpu";
  lifecycle = "manual"; }`, and rename the prism
  instances to `llama-prism-rocm` / `llama-prism-nvidia`.
- `hosts/pvl-l5/services/ai.nix`: rename to `llama-rocm` / `llama-nvidia`, add
  `{ instance = "llama-cpu"; lifecycle = "manual"; }`.

Ports are not repeated in `ai.nix`; they come from `exposedPorts`.

### Ollama

For each of `hosts/pvl-a1/services/ollama.nix` and
`hosts/pvl-l5/services/ollama.nix`:

1. Rename `ollama` (ROCm) to `ollama-rocm` and set its port to `12434`; rename
   `ollama-nvidia` and set its port to `13434`.
2. Add `ollama-cpu` (CPU+Vulkan) at `11434`:

```nix
ollama-cpu = rec {
  exposedPorts.main.port = 11434;

  source = ''
    services:
      ollama-cpu:
        image: docker.io/ollama/ollama:0.34.2
        container_name: ollama-cpu
        ports:
          - "${toString exposedPorts.main.port}:11434"
        volumes:
          - ./ollama_cpu_data:/root/.ollama
          - ${ollamaModelsDir}:/models
        environment:
          - OLLAMA_CONTEXT_LENGTH=131072
          - OLLAMA_MODELS=/models
          - OLLAMA_VULKAN=1
          - OLLAMA_FLASH_ATTENTION=1
          - OLLAMA_KV_CACHE_TYPE=q8_0
          - OLLAMA_KEEP_ALIVE=10m
        devices:
          - "/dev/dri:/dev/dri"
        group_add:
          - keep-groups
  '';

  serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
};
```

3. Update the host policy, pinning `instance` explicitly now that the canonical
   `ollama` name is gone:
   - `hosts/pvl-a1/services/ai.nix`: rename the Ollama deployment instances to
     `ollama-rocm` / `ollama-nvidia`, and add
     `{ instance = "ollama-cpu"; lifecycle = "manual"; }`.
   - `hosts/pvl-l5/services/ai.nix`: same, keeping the existing `stopped`
     lifecycles on `ollama-rocm` / `ollama-nvidia`.

`OLLAMA_CONTEXT_LENGTH`, `OLLAMA_KV_CACHE_TYPE`, the context length, and the
per-host data dir differ today; keep the host-local values and change only the
image, ports, devices, and instance names. Whether `/dev/dri` (Vulkan render
node) should be mounted at all is discussed in D7; drop it for a pure-CPU
variant.

Consider renaming the host file `llama-router.nix` to `llama.nix` for symmetry
with the new instance names; `default.nix` imports it. This is cosmetic and
optional.

### Ollama (`pvl-x2`)

`pvl-x2` currently runs one ROCm Ollama at `11434`. Split it into two:
`ollama-cpu` (default image, `OLLAMA_VULKAN=1`, `/dev/dri`, `11434`) and
`ollama-rocm` (the existing `:0.34.2-rocm` image, `12434`). Keep the host's
existing context/KV/keep-alive values, and give each container its own data dir
(`./ollama_cpu_data`, `./ollama_data`). The registry `ollama` entry keeps
`11434` (the default/Vulkan endpoint); decide whether `openFirewall` should also
cover `12434`.

## Breaking Changes and Migration

### Mutable client profiles (operator state, not repo-owned)

Retarget existing llama.cpp providers and add the CPU provider. Recommended
mapping:

| Profile            | Old endpoint | New endpoint                | Notes                 |
| ------------------ | ------------ | --------------------------- | --------------------- |
| `local-cpu-llama`  | (new)        | `http://localhost:11000/v1` | CPU, after hand-start |
| `local-rocm-llama` | `11000`      | `http://localhost:12000/v1` | retarget to ROCm      |
| `local-nv-llama`   | `12000`      | `http://localhost:13000/v1` | retarget to NVIDIA    |

Every local variant carries its device tag; the `-llama` suffix still marks the
backend. Update on both `pvl-a1` and `pvl-l5`:

- Codex: `~pvl/.codex/<name>.config.toml` and
  `~pvl/.codex/local-rocm-llama-catalog.json`.
- Pi: `~pvl/.pi/agent/models.json`.
- OpenCode: `~pvl/.config/opencode/opencode.jsonc`.

`pvl-x2` has no llama.cpp deployment; its Ollama profiles are below.

Ollama profiles (a1/l5). Every local variant carries its device tag, so the
naked `local` becomes `local-rocm`:

| Profile      | Old profile | Old port | New port | Device     |
| ------------ | ----------- | -------- | -------- | ---------- |
| `local-cpu`  | (new)       | -        | `11434`  | CPU+Vulkan |
| `local-rocm` | `local`     | `11434`  | `12434`  | iGPU/ROCm  |
| `local-nv`   | `local-nv`  | `12434`  | `13434`  | NVIDIA     |

`pvl-x2` Ollama profiles:

| Profile   | Old port | New port | Device |
| --------- | -------- | -------- | ------ |
| `x2`      | `11434`  | `11434`  | Vulkan |
| `x2-rocm` | (new)    | `12434`  | ROCm   |

Open WebUI needs no source change: `hosts/<host>/services/openwebui.nix` derives
`OLLAMA_BASE_URLS` from the Ollama projection, so it picks up the new ports and
the `ollama-cpu` deployment on recreation.

### Systemd unit and ready-target churn

Renaming instances changes deployment units (`pvl-llama-router` →
`pvl-llama-rocm`, etc.). The auto ready target changes to
`pvl-llama-rocm-ready.target` on `pvl-a1`. Reconciler units
(`pvl-llama-router-models[-load]`, `pvl-llama-router-prism-models[-load]`) keep
their runtime-based names. The old units are stopped and removed by
podman-compose instance reconciliation; this is one-time switch churn, not a
data change. State files are runtime-keyed and unaffected.

### Live port conflicts during switch

On `pvl-a1`, old manual NVIDIA containers can occupy ports the new map assigns
to ROCm: old `llama-router-nvidia` on `12000` and new `llama-rocm` on `12000`;
old `llama-router-prism-nvidia` on `12001` and new `llama-prism-rocm` on
`12001`. Required order:

1. Stop the manually-started GPU containers on `pvl-a1` first:
   `pvl-llama-router-nvidia`, `pvl-llama-router-prism-nvidia`, and any running
   `pvl-llama-router-prism`.
2. Apply the Nix change so the compose helper recreates the auto ROCm/PrismML
   ROCm containers on their new ports.
3. Start `pvl-llama-cpu` by hand to validate.

`pvl-l5` has only stopped GPU deployments, so no live conflict exists there.

### VS Code port-forward hazard

The documented `12000` forward incident keeps its historical description, but
the hazard now sits on the new ports: a pinned Remote SSH forward can claim
`11000`, `12000`, or `13000` before Podman. Operators remove or remap the
forward in the VS Code Ports view before hand-starting a deployment.

## Non-Goals

- No NVIDIA device class on `pvl-x2` (AMD-only); its llama.cpp set is CPU/ROCm
  only.
- No `lib/` helper de-duplicating the near-identical `pvl-a1`/`pvl-l5` compose
  sources; host files keep owning container definitions.
- No vLLM/SGLang implementation; ports and names are reserved only, and their
  CPU classes are skipped.
- No Open WebUI source change; it derives `OLLAMA_BASE_URLS` from the Ollama
  projection and picks up the new ports/deployments automatically.
- No client-config writes from Nix; the profile updates above are operator
  steps.

## Open Questions

1. PrismML CPU: `11001` is reserved but there is no CPU asset. Build the fork
   from source for CPU, or leave `llama-prism-cpu` undocumented?
2. Rename `hosts/<host>/services/llama-router.nix` to `llama.nix`, and rename
   `services.ai.backends.llamaRouter` to `llama` in a later lib change?
3. vLLM/SGLang: per-model deployments or a gateway in front of workers?

## Risks

- **RAM pressure.** `--models-max=2` keeps two CPU model sets resident. Combined
  with `sleep-idle-seconds = 300`, validate `free -h` after loading the largest
  selected model (9B Q4).
- **Image-version drift.** The updater tracks `server-`, `server-rocm-`, and
  `server-cuda-` independently, so all three must be bumped in one change and
  verified with the updater's report mode. vLLM/SGLang tags add more independent
  lines when they land.
- **Migration race.** Starting the new ROCm container before stopping the old
  NVIDIA container fails on the shared `12000`/`12001` ports.
- **Client outage.** Every mutable client profile pointing at `11000`/`12000`
  (llama.cpp) or `11434`/`12434` (Ollama) must be updated in the same rollout or
  it breaks silently.
- **CPU cold-load latency.** First request for a cold 9B model on CPU is slow
  and may exceed client timeouts; document it as expected fallback behavior.
- **Reserved-port drift.** vLLM/SGLang reservations are documentation until
  implemented; a future implementer must use the reserved block rather than
  picking adjacent free ports.

## Verification

1. Evaluate both host closures (`pvl-a1`, `pvl-l5`); no assertion fails.
2. Confirm `runtimesInfo.default.portsByName` is
   `{ llama-cpu = 11000; llama-rocm = 12000; llama-nvidia = 13000; }`, and
   `ports`/`urls` match.
3. Confirm PrismML ports are `12001`/`13001` on `pvl-a1`.
4. Render the compose stack and confirm three services for the default runtime,
   each mounting the same staged `models.ini`, with `11000:8080` on the CPU
   service and no GPU devices.
5. Hand-start `llama-cpu`, query `/v1/models`, load a small model, and confirm
   `podman inspect` shows no GPU devices.
6. Confirm a model downloaded by ROCm is visible to CPU from the shared cache.
7. Confirm the reconciler probes a URL list that includes all three ports.
8. Confirm no host service outside this plan uses `11000`-`11299` /
   `12000`-`12299` / `13000`-`13299`.
9. Confirm Ollama projects as `11434`/`12434`/`13434` and Open WebUI's
   `OLLAMA_BASE_URLS` reflects them.
10. Evaluate `pvl-x2` and confirm Ollama projects as `11434` (Vulkan) and
    `12434` (ROCm).

## Docs To Update On Implementation

- `.agents/docs/notes/hosts/pvl-ai-backend-port-convention-2026-09.md`: replace
  the convention table with the device-class scheme, the instance names, the
  reserved vLLM/SGLang blocks, and the updated profile table; keep the
  historical `12000` incident as history.
- `.agents/docs/notes/services/ai-model-service-2026-09.md`: fleet policy for
  the CPU deployment, renames, and renumbered ports on both hosts.
- `.agents/docs/notes/services/llama-router-model-reconciler-2026-09.md`: note
  the device-class set, renamed instances, and new ports.
- `.agents/docs/README.md`: index the implementation note that supersedes this
  plan.
- Format all changed Markdown with `deno fmt`.

## Rollout

1. Implement the host-plane change (compose instances + policy deployments); no
   host activation is required by the source change.
2. Deploy and verify evaluation, port projections, and compose render.
3. On `pvl-a1`, stop the manually-started old NVIDIA/PrismML containers, apply,
   then validate ROCm on `12000` and PrismML ROCm on `12001`.
4. Hand-start `pvl-llama-cpu`, validate, and confirm the shared cache.
5. Update the mutable Codex/Pi/OpenCode profiles to the new ports.
6. Record the final scheme, lifecycle, and tuning in the durable notes above.
7. Later, when vLLM/SGLang are implemented, take the reserved blocks and add the
   backend options in a separate `lib/services/ai` phase.
