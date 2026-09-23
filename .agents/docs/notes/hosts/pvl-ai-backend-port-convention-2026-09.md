# Pvl AI Backend Port Convention

On 2026-09-21, `pvl-ollama-nvidia.service` failed to start on `pvl-a1` because
VS Code already owned `127.0.0.1:11435`. The listener belonged to a local VS
Code process connected through its Remote SSH tunnel to `pvl-l5`, not an SSH
configuration `LocalForward`. The remote service was inactive while the local
listener remained, which is consistent with a saved/restored VS Code Ports
forward; current process state does not establish whether the forward was
originally automatic or manual.

This was not an ephemeral-port collision: `pvl-a1` uses the Linux ephemeral
range `32768-60999`. It was an explicit VS Code application forward colliding
with Podman Compose's publication of `11435:11434` on all host addresses.

The convention is device-class first, then backend, then runtime/model slot:

| Device       | Block   |
| ------------ | ------- |
| CPU + Vulkan | `11xxx` |
| ROCm         | `12xxx` |
| NVIDIA       | `13xxx` |

`port = deviceBase + backendBlock + slot`, with `deviceBase` CPU `11000`, ROCm
`12000`, NVIDIA `13000`; `backendBlock` llama.cpp `0`, vLLM `100`, SGLang `200`;
and `slot` the runtime or served model (`0`-`99`). Ollama keeps its `434` suffix
and maps the device class to the thousands digit.

| Backend/runtime   | CPU/Vulkan |    ROCm |  NVIDIA |
| ----------------- | ---------: | ------: | ------: |
| Ollama            |    `11434` | `12434` | `13434` |
| llama.cpp default |    `11000` | `12000` | `13000` |
| llama.cpp PrismML |          - | `12001` | `13001` |
| vLLM (reserved)   |    `11100` | `12100` | `13100` |
| SGLang (reserved) |    `11200` | `12200` | `13200` |

Instance names drop the bare `llama-router` in favor of `llama-<device>` /
`llama-prism-<device>`, and Ollama uses `ollama-cpu` / `ollama-rocm` /
`ollama-nvidia`. "Router" is a llama.cpp mode, not an identity. PrismML has no
CPU asset, so `11001` is reserved. vLLM and SGLang are not deployed; their
blocks are reserved so a later implementation does not renumber llama.cpp again.

`pvl-a1`: Ollama `ollama-cpu` (manual), `ollama-rocm` (auto), `ollama-nvidia`
(manual); llama.cpp `llama-cpu` (manual), `llama-rocm` (auto), `llama-nvidia`
(manual); PrismML `llama-prism-rocm` (auto), `llama-prism-nvidia` (manual).

`pvl-l5`: Ollama `ollama-cpu` (manual), `ollama-rocm` (stopped), `ollama-nvidia`
(stopped); llama.cpp `llama-cpu` (manual), `llama-rocm` (stopped),
`llama-nvidia` (stopped); PrismML `llama-prism-rocm` (stopped),
`llama-prism-nvidia` (stopped).

`pvl-x2`: Ollama `ollama-rocm` (`12434`, auto, the primary backing Open WebUI)
and `ollama-cpu` (CPU + Vulkan, `11434`, manual fallback); llama.cpp
`llama-rocm` (`12000`, manual) and `llama-cpu` (`11000`, manual), PrismML
`llama-prism-rocm` (`12001`, manual); AMD-only, so no NVIDIA device class. Its
`ollama` service registry entry stays `11434` (the default/Vulkan endpoint);
both ports are firewall-open.

The per-user AI client configuration is mutable state, not owned by this
repository. All `local*` variants are device-tagged:

| Profile            | Endpoint                    |
| ------------------ | --------------------------- |
| `local-cpu`        | `http://localhost:11434/v1` |
| `local-rocm`       | `http://localhost:12434/v1` |
| `local-nv`         | `http://localhost:13434/v1` |
| `local-cpu-llama`  | `http://localhost:11000/v1` |
| `local-rocm-llama` | `http://localhost:12000/v1` |
| `local-nv-llama`   | `http://localhost:13000/v1` |
| `x2`               | `http://pvl-x2:11434/v1`    |
| `x2-rocm`          | `http://pvl-x2:12434/v1`    |

For Codex, these are named `~pvl/.codex/<name>.config.toml` files plus the
`local-rocm-llama-catalog.json` catalog; the main `~pvl/.codex/config.toml`
stays outside this update. Pi uses `~pvl/.pi/agent/models.json` and OpenCode
uses `~pvl/.config/opencode/opencode.jsonc`. Do not invent a provider on a host
where it is absent.

Renaming instances moves each compose working dir to
`/var/lib/pvl/compose/<instance>`. Staged `models.ini` files regenerate and
llama.cpp GGUFs live in the fixed `/var/lib/pvl/ai/llama-router` cache, so on
`pvl-a1`/`pvl-l5` only per-instance Ollama metadata is left behind. On `pvl-x2`,
existing model blobs lived in the old `/var/lib/pvl/compose/ollama` working dir;
migrate them once into the stack-wide store:
`install -d -o pvl -g pvl /var/lib/pvl/ollama-models && cp -a
/var/lib/pvl/compose/ollama/ollama_data/models/. /var/lib/pvl/ollama-models/`.

For Codex, these are the named `~pvl/.codex/<name>.config.toml` files. The main
`~pvl/.codex/config.toml` is intentionally outside this endpoint update. Pi uses
`~pvl/.pi/agent/models.json`, and OpenCode uses
`~pvl/.config/opencode/opencode.jsonc`. These files are mutable user state, not
owned by this Nix repository, so a future port migration must update their
existing provider entries separately. Do not invent `local-nv` or `x2` providers
on a host where they are absent.

VS Code has no numeric range that it categorically excludes from application
auto-forwarding, so these values do not guarantee that a future forwarded remote
endpoint cannot claim the same-numbered local socket while a manual backend is
stopped. They do avoid the retained `11435` forward that caused this incident
and keep the service topology legible without changing VS Code policy.

Do not duplicate these ports in Open WebUI or reconciler configuration. The
shared `services.ai` module derives Ollama and llama.cpp URL/port projections
from each `services.podman-compose.pvl.instances.<name>.exposedPorts`
declaration. Open WebUI consumes the Ollama projection; each model reconciler
consumes its backend projection.

Validation proves on all three AI hosts:

- Ollama projects as `11434` / `12434` / `13434` (`pvl-x2`: `11434` / `12434`);
- llama.cpp projects as `11000` / `12000` / `13000`, PrismML as `12001` /
  `13001`;
- Compose publishes the expected host-to-container mappings;
- Open WebUI receives the derived Ollama endpoints;
- the complete host closure still evaluates with no failed assertions.

The source change does not deploy or restart any backend. After deployment,
clear the failed user unit and start `pvl-ollama-nvidia.service`; then verify
the `12434` listener and its `/api/tags` response before treating the runtime
collision as resolved.

## 2026-09-22 llama.cpp NVIDIA collision

`pvl-llama-router-nvidia.service` later failed on `pvl-a1` for the same class of
socket conflict, but the saved VS Code state made the source unambiguous. The
Remote SSH connection to `pvl-l5` contained a `User Forwarded` tunnel from
remote `12000` to local `12000`. Nearby saved tunnels were marked
`Auto Forwarded` and had been remapped when their preferred local ports were
unavailable. The manually pinned tunnel instead claimed the exact local port
needed by Podman.

Incident recovery removed only the persisted same-port entry and recycled the
shared VS Code tunnel utility process which owned the listener. Once the router
claimed local `12000`, the active VS Code session restored the user forward as
remote `12000` to local `12001`. That resolved the default-router collision but
claimed the declared manual Prism/CUDA port, so it was not a generally
non-conflicting mapping. The declarative `11001`/`12001` Prism pair is retained
because mutable Pi and OpenCode providers consume it; the VS Code forward must
be removed or remapped before starting Prism/CUDA. Routine recovery should use
the VS Code Ports view; direct editing of VS Code's state database was a
surgical incident action, not a normal operating procedure.

Do not manually pin a remote model service to the same local port on a client
which may also run that backend locally. After releasing the tunnel,
`pvl-llama-router-nvidia.service` became active, Compose published
`0.0.0.0:12000->8080`, `/v1/models` returned 14 entries, and a request loaded
`/app/llama-server` on the RTX 4060 with 4416 MiB of GPU memory. The repaired
`/var/lib/pvl/ai` ownership hierarchy was already correct and was unrelated to
this failure.

## Manual llama.cpp client profiles

The mutable client configuration on `pvl-a1` and `pvl-l5` uses device-tagged
backend names (superseding the earlier `local-llama` / `local-nv-llama`):

| Profile/provider   | Endpoint                    |
| ------------------ | --------------------------- |
| `local-cpu-llama`  | `http://localhost:11000/v1` |
| `local-rocm-llama` | `http://localhost:12000/v1` |
| `local-nv-llama`   | `http://localhost:13000/v1` |

Codex owns the named `~/.codex/<name>.config.toml` profiles plus a shared
`~/.codex/local-rocm-llama-catalog.json`; the main `~/.codex/config.toml`
remains untouched. Pi carries the same provider names in
`~/.pi/agent/models.json`, and OpenCode carries them in
`~/.config/opencode/opencode.jsonc`. `pvl-x2` has no llama.cpp deployment.
Future backend profiles retain the device tag plus the backend suffix, for
example `local-sgl` and `local-vllm`.

Pi and OpenCode expose the seven-model `pvl-a1`/`pvl-l5` host selection through
both llama.cpp providers. Their existing local and local-NVIDIA Ollama menus
were converged to that selection at the same time; OpenCode's NVIDIA Ollama URL
was normalized to its `/v1` endpoint. The llama.cpp embedding alias is
`nomic-embed-text`, while Ollama reports the same logical model as
`nomic-embed-text:latest`.

Codex uses the Responses API and currently exposes only `gemma4:e2b` and
`gemma4:e4b` through its llama.cpp catalog, with E2B as the default. The current
Qwen 3.5 embedded Jinja templates reject Codex's sequence of developer messages
with `System message must be at the beginning`; Pi and OpenCode use compatible
Chat Completions payloads and retain the Qwen entries. Live validation proved
Codex Responses plus an `exec_command` tool call, Pi Chat Completions, and
OpenCode Chat Completions on port `11000`, and all three clients on the NVIDIA
router at `12000`.

These files remain manually maintained user state. The shared Nix model catalog
does not project client files, by design for this phase.

## Applied client config migration, 2026-09-23

The device-class provider renames were applied directly to the mutable client
configs on `pvl-a1`, `pvl-l5`, and `pvl-x2` (they are not repo-owned). Each host
has a timestamped backup under `/home/pvl/.client-config-backup-20260923-110133`
(`models.json`, `settings.json`, `opencode.jsonc`, and the Codex config/catalog
files; removed files are kept with a `.removed` suffix).

Applied provider sets:

- `pvl-a1`/`pvl-l5`: Ollama `local-cpu` (11434), `local-rocm` (12434),
  `local-nv` (13434); llama.cpp `local-cpu-llama` (11000), `local-rocm-llama`
  (12000), `local-nv-llama` (13000); PrismML `local-rocm-llama-prism` (12001),
  `local-nv-llama-prism` (13001); remote `x2` (`pvl-x2:11434`) and `x2-rocm`
  (`pvl-x2:12434`).
- `pvl-x2`: Ollama `local-cpu` (11434), `local-rocm` (12434); llama.cpp
  `local-cpu-llama` (11000), `local-rocm-llama` (12000); PrismML
  `local-rocm-llama-prism` (12001).

Pi `settings.json` defaults were updated: `pvl-a1` `local` → `local-rocm`,
`pvl-l5` `pvl-x2` → `x2`. Legacy untagged Codex profiles (`local`, `local-llama`
on a1/l5, `local` on x2) were removed. The Codex profiles now match Pi for
Ollama and the default llama.cpp runtime on a1/l5.

Deferred in this migration: no client providers for `pvl-x2`'s llama.cpp or
PrismML endpoints, and no Codex PrismML profiles. `pvl-x2`'s llama deployments
are `manual`, so those providers can be added when the service posture is
settled.
