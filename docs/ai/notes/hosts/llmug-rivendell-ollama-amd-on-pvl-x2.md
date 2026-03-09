# llmug-rivendell Ollama AMD GPU Reconfiguration

## Context

- `llmug-rivendell` runs as an Incus container on `pvl-x2`.
- `pvl-x2` provides AMD GPU devices, not NVIDIA CDI runtime support.
- Ollama service definitions were still wired for NVIDIA and could not start.

## Final state

- `hosts/llmug-rivendell/services.nix` now grants Ollama access to `/dev/dri`
  and `/dev/kfd` and adds `video` and `render` groups.
- `hosts/llmug-rivendell/podman.nix` matches that device and group model for the
  containerized Ollama service.
- `hosts/llmug-rivendell/default.nix` no longer imports NVIDIA-specific host
  assumptions for this workload.

## Effect

- Ollama on `llmug-rivendell` is aligned with AMD GPU access on `pvl-x2` instead
  of depending on NVIDIA-specific runtime wiring.
