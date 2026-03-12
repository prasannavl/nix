# Incus Guest Ollama AMD GPU Reconfiguration

## Context

- The guest runs as an Incus container on its parent host.
- The parent host provides AMD GPU devices, not NVIDIA CDI runtime support.
- The original Ollama wiring assumed NVIDIA and could not start here.

## Final state

- `hosts/<guest>/services.nix` now grants Ollama access to `/dev/dri`
  and `/dev/kfd` and adds `video` and `render` groups.
- `hosts/<guest>/podman.nix` matches that device and group model for the
  containerized Ollama service.
- `hosts/<guest>/default.nix` no longer imports NVIDIA-specific host
  assumptions for this workload.

## Effect

- Keep guest GPU assumptions aligned with the actual parent host hardware.
- For this workload, AMD device passthrough replaces NVIDIA-specific runtime
  assumptions.
