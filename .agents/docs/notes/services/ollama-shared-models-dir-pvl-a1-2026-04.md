# Ollama Shared Models Dir On `pvl-a1` 2026-04

`pvl-a1` keeps separate per-instance Ollama homes for the ROCm-backed `ollama`
instance and the disabled-by-default `ollama-nvidia` instance, but mounts a
single shared host directory for model storage into both containers.

Shape:

- `./ollama_data:/root/.ollama` stays dedicated to the ROCm instance.
- `./ollama_nvidia_data:/root/.ollama` stays dedicated to the NVIDIA instance.
- `/var/lib/pvl/ollama_models:/models` is mounted into both instances.
- `OLLAMA_MODELS=/models` is set on both instances so pulled models are shared.
- The shared host directory is created via `systemd.tmpfiles.rules` as
  `pvl:pvl`, not from the rootless user-service pre-start path.

Reason:

- Ollama officially supports relocating the models directory via
  `OLLAMA_MODELS`.
- Sharing only the model store is the conservative topology: model blobs and
  manifests are shared, while per-instance runtime state under `/root/.ollama`
  remains isolated.
- Relative paths like `./ollama_models` are not sufficient here because
  `services.podman-compose.<stack>.instances.<name>` resolves them under each
  instance's own compose working directory, producing two different host paths.
- The live host already used `/var/lib/pvl/ollama_models`; an earlier draft
  mistakenly switched the absolute path to `/var/lib/pvl/ollama-models`, which
  made the bootstrap check look at the wrong location and triggered the
  permission failure when the rootless service tried to create that new sibling
  directory under `/var/lib/pvl`.
- A rootless per-user service must not be responsible for first-creating a new
  child under `/var/lib/pvl`; that host path should exist already through
  system-level tmpfiles management.
- Prefer one writer at a time for pull/create/prune style operations if avoiding
  duplicate work matters, even though the underlying cache code guards
  concurrent writes.

## 2026-06 model-pull unit shape

`pvl-a1` keeps the `131072` context length and AMD/ROCr environment on its ROCm
Ollama backend, but its `pvl-ollama-models.service` now matches the split
backend orchestration used on `pvl-l5`:

- `After=` orders it behind both `pvl-ollama.service` and
  `pvl-ollama-nvidia.service`.
- `Wants=` includes only `network-online.target`, so model pulls do not start a
  stopped backend during `systemd-user-manager` reconcile.
- `autoStart = false` keeps `systemd-user-manager` from immediately starting the
  model-pull unit during boot; `pvl-ollama-models-boot.timer` starts it 2
  minutes after boot instead, giving Ollama time to expose its API and keeping
  model pulls out of the earliest startup work.
- `OLLAMA_URLS` includes both local backend endpoints, `127.0.0.1:11434` and
  `127.0.0.1:11435`, letting `lib/services/ollama/helper.sh` pull through
  whichever backend API is reachable.
- restart triggers include the normalized `ollama` and `ollama-nvidia` Podman
  Compose instance configs so backend config changes rerun the model-pull
  helper.
