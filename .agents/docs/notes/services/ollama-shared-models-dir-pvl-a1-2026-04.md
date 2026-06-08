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
  `services.podmanCompose.<stack>.instances.<name>` resolves them under each
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
