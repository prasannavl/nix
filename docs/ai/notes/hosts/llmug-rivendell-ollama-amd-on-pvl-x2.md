# llmug-rivendell Ollama AMD GPU Reconfiguration

## Context

- `llmug-rivendell` runs as an Incus container on `pvl-x2`.
- `pvl-x2` provides AMD GPU devices, not NVIDIA CDI runtime support.
- The original Ollama wiring assumed NVIDIA and could not start here.

## Final state

- `hosts/llmug-rivendell/services.nix` now grants Ollama access to `/dev/dri`
  and `/dev/kfd` and adds `video` and `render` groups.
- `hosts/llmug-rivendell/podman.nix` matches that device and group model for the
  containerized Ollama service.
- `hosts/llmug-rivendell/default.nix` no longer imports NVIDIA-specific host
  assumptions for this workload.

## Effect

- Keep guest GPU assumptions aligned with the actual parent host hardware.
- For this workload, AMD device passthrough replaces NVIDIA-specific runtime
  assumptions.
