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

The dual-backend hosts now use a backend-family convention instead of adjacent
ports:

| Backend          | Local/ROCm |  NVIDIA |
| ---------------- | ---------: | ------: |
| Ollama           |    `11434` | `12434` |
| llama.cpp router |    `11000` | `12000` |

The convention is identical on `pvl-a1` and `pvl-l5`. `pvl-x2` keeps its only
Ollama deployment on the native `11434` and has no alternate NVIDIA or llama.cpp
deployment.

The per-user AI client configuration for `pvl` follows the same Ollama
endpoints:

| Client config | `pvl-a1` | `pvl-l5` | `pvl-x2` |
| ------------- | -------- | -------- | -------- |
| `local`       | `11434`  | `11434`  | `11434`  |
| `local-nv`    | `12434`  | `12434`  | absent   |
| `x2`          | `11434`  | `11434`  | absent   |

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

Validation should prove on both dual-backend hosts:

- Ollama ports and URLs project as `11434` and `12434`;
- llama.cpp ports and URLs project as `11000` and `12000`;
- Compose publishes the expected host-to-container mappings;
- Open WebUI receives both derived Ollama endpoints;
- the complete host closure still evaluates.

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
remote `12000` to local `12001`, and persisted that non-conflicting mapping. The
recovery did not change global VS Code forwarding settings, the backend port
convention, or the editor process. Routine recovery should use the VS Code Ports
view to remove or remap the manual forward; direct editing of VS Code's state
database was a surgical incident action, not a normal operating procedure.

Do not manually pin a remote model service to the same local port on a client
which may also run that backend locally. After releasing the tunnel,
`pvl-llama-router-nvidia.service` became active, Compose published
`0.0.0.0:12000->8080`, `/v1/models` returned 14 entries, and a request loaded
`/app/llama-server` on the RTX 4060 with 4416 MiB of GPU memory. The repaired
`/var/lib/pvl/ai` ownership hierarchy was already correct and was unrelated to
this failure.

## Manual llama.cpp client profiles

The mutable client configuration on `pvl-a1` and `pvl-l5` now follows the
backend-first naming convention:

| Profile/provider | Endpoint                    |
| ---------------- | --------------------------- |
| `local-llama`    | `http://localhost:11000/v1` |
| `local-nv-llama` | `http://localhost:12000/v1` |

Codex owns the two named `~/.codex/<name>.config.toml` profiles plus a shared
`~/.codex/local-llama-catalog.json`; the main `~/.codex/config.toml` remains
untouched. Pi carries the same provider names in `~/.pi/agent/models.json`, and
OpenCode carries them in `~/.config/opencode/opencode.jsonc`. `pvl-x2` remains
unchanged because it has no llama.cpp deployment. Future backend profiles should
retain the same suffix convention, for example `local-sgl` and `local-vllm`.

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
