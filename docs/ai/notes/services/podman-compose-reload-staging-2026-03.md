# Podman Compose Reload Staging

- Repo-managed podman compose runtime files are now copied into the per-service
  working directory instead of symlinked from `/nix/store`, so bind-mounted
  container paths do not depend on host-only symlink targets.
- `ExecReload` for generated podman compose systemd user services now runs a
  dedicated reload script that performs `down`, staged-file cleanup, staged-file
  recreation, and `up -d --remove-orphans`.
- This makes reload honor the same staging contract as stop plus start, so
  removed or renamed runtime files do not linger across reloads.
