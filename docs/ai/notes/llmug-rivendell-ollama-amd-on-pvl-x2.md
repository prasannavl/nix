# llmug-rivendell Ollama AMD GPU reconfiguration for pvl-x2

## Context
- `llmug-rivendell` runs as an Incus container on `pvl-x2`.
- `pvl-x2` has an AMD iGPU (Strix/Hawk Point class), no NVIDIA GPU.
- Ollama service definitions on `llmug-rivendell` were hardcoded to NVIDIA CDI (`nvidia.com/gpu=all`), causing startup failure.

## Changes made
- Updated `hosts/llmug-rivendell/services.nix` (`services.podmanCompose.llmug.services.ollama`) to use AMD-accessible devices:
  - Added `group_add: [video, render]`
  - Replaced device mapping with `/dev/dri:/dev/dri` and `/dev/kfd:/dev/kfd`
- Updated `hosts/llmug-rivendell/podman.nix` (`virtualisation.oci-containers.containers.ollama`) similarly:
  - Added `--group-add=video`, `--group-add=render`
  - Replaced `--device=nvidia.com/gpu=all` with `--device=/dev/dri:/dev/dri` and `--device=/dev/kfd:/dev/kfd`
- Removed NVIDIA-specific host assumptions from `hosts/llmug-rivendell/default.nix`:
  - Dropped `../../lib/hardware/nvidia.nix` import
  - Removed `hardware.nvidia.prime` block

## Expected result
- Ollama no longer depends on NVIDIA runtime plumbing.
- On `pvl-x2`, llmug-rivendell should use AMD GPU nodes exposed by Incus (`/dev/dri`, `/dev/kfd`) for hardware acceleration.
