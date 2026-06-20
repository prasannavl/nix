# PVL-L5 AI Services Port 2026-06

`pvl-l5` imports `hosts/pvl-l5/services`, which ports the local `pvl-a1` Ollama
and Open WebUI service layout onto the Legion host.

Service shape:

- `services.podman-compose.pvl` uses user `pvl`, stack directory
  `/var/lib/pvl/compose`, and service prefix `pvl-`.
- `ollama` runs the ROCm image on host port `11434`, mounts `/dev/kfd` and
  `/dev/dri`, and stores shared model data at `/var/lib/pvl/ollama-models`.
- `ollama-nvidia` is declared with the same shared model store on host port
  `11435`, but its desired state is `stopped` so it is available for manual use
  without starting by default.
- `openwebui` runs on host port `4000` and points at both Ollama backends via
  `host.containers.internal`.
- `pvl-ollama-models.service` pulls the same required model list as `pvl-a1`
  after `pvl-ollama.service` is available.

Validation:

- `alejandra hosts/pvl-l5/default.nix hosts/pvl-l5/services/default.nix hosts/pvl-l5/services/ollama.nix hosts/pvl-l5/services/openwebui.nix`
- `nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw`

The eval required temporary `git add -N` for the new service files because flake
source filtering does not include untracked imported paths.
