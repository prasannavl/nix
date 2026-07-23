# User Services Platform

## Scope

Canonical platform notes for Podman compose stacks, shared nginx rendering, and
service-facing ingress policy.

## Podman compose model

- Shared compose implementation lives in `lib/podman-compose/`. Base Podman
  enablement defaults live in `lib/podman.nix`.
- `services.podman-compose.<stack>.instances` is the canonical instance shape.
- Generated runtime trees are store-backed, staged at service start, and cleaned
  through runtime manifests rather than handwritten ad hoc cleanup.
- If a compose instance declares a stable default-network subnet, record it in
  `subnet`; duplicate declared subnets are rejected at evaluation time. Inline
  compose network IPAM is not parsed for collision checks.
- Duplicate `exposedPorts` host port/protocol pairs are rejected at evaluation
  time.
- `services.podman-compose.<stack>.timeoutReadySeconds` is the stack default for
  generated user-manager stable-state waits; instances may override it with
  `services.podman-compose.<stack>.instances.<name>.timeoutReadySeconds`.
- The main generated service is a bounded `Type=oneshot` unit with
  `RemainAfterExit=true` and `Restart=no`. It uses
  `podman compose up -d --remove-orphans`, verifies startup state, and exits
  successfully without retaining an automatic restart monitor.
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
- Main compose units use `KillMode=mixed`: the helper receives the graceful stop
  signal, while inherited `conmon` and `fuse-overlayfs` processes remain alive
  for helper-owned compose cleanup. Systemd still applies the final hard kill to
  the complete cgroup after the stop timeout.
- `TimeoutStopSec` is at least 240 seconds and grows with `timeoutReadySeconds`,
  leaving room for the 180-second shared rootless lock queue, the bounded
  compose stop, and cleanup before the hard-kill boundary.
- The helper's start-stall watchdog is a hard failed-start boundary. Startup
  owns one initial attempt and one repair/recreate attempt. A failed second
  attempt leaves the oneshot unit failed; systemd does not turn it into another
  lifecycle wave.

## Configuration and secrets

- `exposedPorts` is the source of truth for host port exposure, firewall
  opening, nginx reverse proxy generation, and Cloudflare tunnel ingress.
- `dirs` is the source of truth for managed service directories. Relative keys
  are resolved under the compose working directory; absolute keys manage host
  paths directly.
- `envSecrets` is the canonical file-backed secret injection mechanism.
- Repo-managed age secret source changes are included in restart stamps when the
  configured secret runtime path maps back to `config.age.secrets`; the
  encrypted age file is content-hashed even when it is reached through the
  flake's store source path, so unrelated repo commits do not look like secret
  rotations. Use `bootTag` for secret files outside that model when a managed
  restart is required.
- Trusted CA `sourceHashInputs` are content-hashed for the same reason. Do not
  use Nix store path identity for repo source files here: dirty-staged deploys
  create a generation-specific flake source path and would otherwise restart
  every CA-consuming service on unrelated staged changes.

## Lifecycle tags

- `state = "running" | "stopped"` is the public desired-state knob for
  `services.podman-compose.<stack>.instances.<name>`. Stopped instances still
  render metadata and generated units, but the generated user-manager entry uses
  `state = "stopped"` to stop the unit and avoid auto-starting it. Podman
  runtime files are staged on manual or automatic start and cleaned after stop.
  This cleanup is intentional: stopped state is still declared ownership, but it
  must not leave stale staged files from an older generation. Resuming the unit
  stages the current generation again. Removal behavior is a separate
  `removalPolicy` path.
- Stack `reconcilePolicy` defaults to `auto`; instance `reconcilePolicy`
  defaults to `inherit` and resolves before helper metadata is generated. `auto`
  uses smart reload/restart/recreate classification, `restart` restarts for
  reload/restart-class and recreate-class drift without force-recreating
  containers, and `recreate` collapses restart-class and recreate-class drift
  into a force-recreate.
- Stack `removalPolicy` defaults to `delete`; instance `removalPolicy` defaults
  to `inherit`. `keep` leaves the old workload running when the declaration is
  removed; `stop` stops containers without deleting compose objects;
  `delete-all` also removes compose volumes and managed staged dirs under the
  working directory. Re-declaration requires matching
  `.podman-compose/state.json` identity state or a one-time `adopt = true`.
- `adopt = true` is a takeover knob, not a steady-state policy. It
  force-recreates containers on start so the adopted runtime matches the
  declaration, regardless of `reconcilePolicy`.
- `bootTag`, `reloadTag`, `recreateTag`, and `imageTag` are explicit operator
  knobs.
- `reloadTag` routes through reloadTriggers for native-reload-capable instances
  and does not affect services where native reload is not enabled.
- `recreateTag != "0"` restarts the managed unit through the reconciler. Under
  `auto` or `recreate`, it makes the helper use
  `podman compose up --force-recreate` once for each new tag value. Under
  `restart`, it restarts without force-recreating containers. The helper records
  the last successful tag in the compose working directory so later boots do not
  replay the same tag.
- Recreate-relevant runtime shape is also folded into a generated
  `recreateStamp`; under `auto` or `recreate`, stamp drift makes the helper run
  `podman compose up --force-recreate`. Under `restart`, the same drift restarts
  without force-recreating containers.
- `imageTag != "0"` enables the auxiliary image-pull unit before the managed
  service starts and is included in recreate intent so changed images are
  consumed automatically when policy allows recreate.
- Systems with compose-backed services also export
  `/run/current-system/share/podman-compose/image-pulls.json` and install
  `podman-compose-image-pull-all`. The deploy-time plan is derived from every
  resolved compose instance with store-backed compose files, not from
  `imageTag`. Nixbot deploys run the built target system's version of that
  helper before activation, so remote image fetches happen in a pre-activation
  deploy phase instead of inside `podman compose up`.
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
- the host service module that declares `services.podman-compose.<stack>`

## Superseded notes

- `docs/ai/notes/services/nginx-soft-backend-deps-2026-04.md`

## Provenance

- This note replaces the earlier dated Podman, nginx, OpenSSH, and lifecycle-tag
  notes for the shared user-services platform, including the standalone nginx
  backend-dependency note.
