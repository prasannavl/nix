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
