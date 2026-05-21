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
- If a compose instance declares a stable default-network subnet, record it in
  `subnet`; duplicate declared subnets are rejected at evaluation time. Inline
  compose network IPAM is not parsed for collision checks.
- Duplicate `exposedPorts` host port/protocol pairs are rejected at evaluation
  time.
- `services.podmanCompose.<stack>.timeoutStableSeconds` is the stack default for
  generated user-manager stable-state waits; instances may override it with
  `services.podmanCompose.<stack>.instances.<name>.timeoutStableSeconds`.
- The main generated service is a long-running unit that uses
  `podman compose up -d --remove-orphans`, verifies startup state, and then
  monitors `podman compose ps --format json`.
- Compose instances are long-running by default; set `longRunning = false` only
  for intentional run-to-completion compose jobs where all containers exiting
  with code 0 is service success.
- `systemctl --user reload <unit>` is available for manual operator use.
  `reload.method = "restart"` is the safe default; native signal reload is
  opt-in and may track directory-mounted `reload.trigger.dirs` paths plus
  explicit `reload.trigger.externalFiles`. Deploy-time `reloadTriggers` route
  reload-safe changes through `systemctl --user reload`; other changes still
  restart.
- `reload.trigger.externalFiles` must name staged files outside the container
  mount contract; exact single-file bind mounts are rejected. Compose-consumed
  files such as `.env` still need restart/recreate for container-visible env or
  interpolation changes.
- Startup success means the containers reached the expected running state, not
  merely that the compose command exited.

## Configuration and secrets

- `exposedPorts` is the source of truth for host port exposure, firewall
  opening, nginx reverse proxy generation, and Cloudflare tunnel ingress.
- `dirs` is the source of truth for managed service directories. Relative keys
  are resolved under the compose working directory; absolute keys manage host
  paths directly.
- `envSecrets` is the canonical file-backed secret injection mechanism.
- Pure secret-content rotation at the same runtime path does not force a restart
  by itself; use `bootTag` when a managed restart is required.

## Lifecycle tags

- `bootTag`, `reloadTag`, `recreateTag`, and `imageTag` are explicit operator
  knobs.
- `reloadTag` routes through reloadTriggers for native-reload-capable instances
  and does not affect services where native reload is not enabled.
- `recreateTag != "0"` restarts the managed unit through the reconciler and
  makes the helper use `podman compose up --force-recreate` once for each new
  tag value. The helper records the last successful tag in the compose working
  directory so later boots do not replay the same tag.
- `imageTag != "0"` enables the auxiliary image-pull unit before the managed
  service starts; use `bootTag` or `recreateTag` when existing containers should
  be restarted after an image pull.
- Tag semantics should depend only on the declared tag value, not on incidental
  generated helper path churn.
- Boots do not replay lifecycle tags. Tags are deploy-time triggers.
- Rootless stack users get a system-level Podman idmap migration check before
  their user-manager dispatcher. It runs `podman system migrate` only when
  subordinate uid/gid ranges exist and Podman's active map is still the stale
  single-id form.

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
- Backend service dependencies discovered from route or vhost metadata should
  stay soft `Wants`-style startup edges, not hard `Requires`.
- Backend outages should degrade to route-level `502` or `504` responses, not
  block nginx startup entirely.

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
- `lib/services/tunnels/cloudflare.nix`
- the host service module that declares `services.podmanCompose.<stack>`

## Superseded notes

- `docs/ai/notes/services/nginx-soft-backend-deps-2026-04.md`

## Provenance

- This note replaces the earlier dated Podman, nginx, OpenSSH, and lifecycle-tag
  notes for the shared user-services platform, including the standalone nginx
  backend-dependency note.
