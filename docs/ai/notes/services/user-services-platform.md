# User Services Platform

## Scope

Canonical platform notes for Podman compose stacks, shared nginx rendering, and
service-facing ingress policy.

## Podman compose model

- Shared implementation lives in `lib/podman-compose/` and the higher-level
  service wiring under `lib/podman.nix`.
- `services.podmanCompose.<stack>.instances` is the canonical instance shape.
- Generated runtime trees are store-backed, staged at service start, and cleaned
  through runtime manifests rather than handwritten ad hoc cleanup.
- The main generated service is a long-running unit that uses
  `podman compose up -d --remove-orphans` followed by `podman compose wait`.
- Reload should restage files before bringing the stack back up.
- Startup success means the containers reached the expected running state, not
  merely that the compose command exited.

## Configuration and secrets

- `exposedPorts` is the source of truth for host port exposure, firewall
  opening, nginx reverse proxy generation, and Cloudflare tunnel ingress.
- `envSecrets` is the canonical file-backed secret injection mechanism.
- Pure secret-content rotation at the same runtime path does not force a restart
  by itself; use `bootTag` when a managed restart is required.

## Lifecycle tags

- `bootTag`, `recreateTag`, and `imageTag` are explicit operator knobs.
- Tag semantics should depend only on the declared tag value, not on incidental
  generated helper path churn.
- Boots do not replay lifecycle tags. Tags are deploy-time triggers.

## Nginx model

- Shared nginx rendering lives under `lib/services/nginx/`.
- Whole-host routing stays on `nginxHostNames`.
- Path-prefix routing uses:
  - `exposedPorts.<name>.nginxRoutes` for dynamic backends
  - `nginxLib.mkStaticSite.routes` for static content
- Whole-host and path-prefix routes for the same hostname should render into a
  single `server` block.
- `stripPath = true` means the backend sees the request without the public mount
  prefix.

## Rate limiting

- Shared nginx reverse-proxy defaults live in one common profile.
- Applications may override, disable, or extend that policy per exposed port.
- The default policy is a baseline guardrail, not a promise that every route has
  the same traffic profile.

## Supporting module rules

- Shared OpenSSH enablement should stay centralized.
- Wrapper-private podman-compose environment variables must not reuse upstream
  `PODMAN_COMPOSE_*` prefixes.

## Source of truth files

- `lib/podman.nix`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/services/nginx/default.nix`
- `lib/services/tunnels/default.nix`
- `hosts/<service-host>/services.nix`

## Provenance

- This note replaces the earlier dated Podman, nginx, OpenSSH, and lifecycle-tag
  notes for the shared user-services platform.
