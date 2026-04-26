# PVL-A1 Inline Compose Migration (2026-04)

- Converted the remaining `hosts/pvl-a1/services/*/docker.compose.yaml` files
  for `ollama` and `openwebui` into inline `source = '' ... '';` definitions in
  their service modules.
- Removed the standalone compose files after migration so the host service
  wiring stays in Nix.
- Flattened the host service layout afterward so those two modules now live at
  `hosts/pvl-a1/services/ollama.nix` and
  `hosts/pvl-a1/services/openwebui.nix` instead of nested `default.nix` files.
- Embedded the remaining `ollama` and `openwebui` environment values directly
  into the inline compose sources and removed the now-redundant staged `.env`
  files.
