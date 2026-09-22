# Pvl Quadlet Host Migration Blockers

## Status

Intentionally deferred, not a missed shared port.

The shared `lib/podman-compose` backend is byte-for-byte identical to Abird and
already defaults stacks to `backend = "quadlet"`. Abird has no explicit Compose
pins, so all of its populated stacks run Quadlet. Pvl's three populated stacks
(`pvl-a1`, `pvl-l5`, `pvl-x2`) explicitly set `backend = "compose"` in
`hosts/pvl-*/services/default.nix`.

The pin was added by `bb8d3a5e fix(podman): retain Compose on Pvl hosts`:

> Current stacks use backend features not yet supported by Quadlet. Pin them
> before changing the shared default.

The port ledger
[`abird-post-d7a-port-2026-08.md`](../tooling/abird-post-d7a-port-2026-08.md)
records the same conclusion and defers a "separate migration" for the
unsupported service shapes.

## Current blocker inventory

The Quadlet path is a strict build-time compiler with no silent Compose
fallback. The compiler in `lib/podman-compose/quadlet-compiler.py` supports a
fixed `ALLOWED_SERVICE_KEYS` set and explicitly rejects signal reload, one-shot
containers, non-`delete` removal policies, named/anonymous volumes, non-default
networks, and `extends`-free Compose shapes. A fresh scan of every Pvl host
service found five unsupported shapes:

| Blocker                                     | Paths                                                                                                                                                                                                    | Compiler behavior                            |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| GPU `deploy.resources.reservations.devices` | `hosts/pvl-a1/services/ollama.nix`, `hosts/pvl-a1/services/llama-router.nix`, `hosts/pvl-l5/services/ollama.nix`, `hosts/pvl-l5/services/llama-router.nix`, `hosts/pvl-x2/services/immich/hwaccel.*.yml` | `deploy` is not an allowed service key       |
| `network_mode: host`                        | `hosts/pvl-x2/services/beszel/default.nix`                                                                                                                                                               | `network_mode` is not an allowed service key |
| Signal reload (`reload.method = "signal"`)  | `hosts/pvl-x2/services/nginx.nix`                                                                                                                                                                        | `signal reload is unsupported`               |
| `extends:`                                  | `hosts/pvl-x2/services/immich/default.nix`                                                                                                                                                               | `extends` is not an allowed service key      |
| Named volume (`model-cache:/cache`)         | `hosts/pvl-x2/services/immich/default.nix`                                                                                                                                                               | `service ... volumes must be bind mounts`    |

The 2026-08 ledger named only the first three; the Immich `extends` and named
volume are additional blockers found by this scan.

## Migration options

1. **Adapt the Pvl compose sources** to the supported subset, keeping the shared
   backend byte-identical to Abird:
   - map GPU reservations to supported `devices:` CDI entries (for example
     `nvidia.com/gpu=all`) where the compiler accepts them;
   - replace Beszel `network_mode: host` with explicit host port maps;
   - change Nginx reload from `signal` to a supported reload/restart method;
   - inline the Immich `extends` files and replace the named `model-cache`
     volume with a bind mount.
2. **Extend the shared Quadlet backend** to support `deploy` GPU reservations,
   `network_mode`, signal reload, `extends`, and named volumes, then upstream
   the identical change to Abird to preserve byte parity.
3. **Hybrid**: extend generic features in the shared backend and adapt only
   Pvl-specific shapes.

Option 1 keeps parity trivially but changes service behavior and needs
per-service validation. Option 2 is the larger cross-repository convergence
project. Either path is a production runtime migration: the next deploy would
drain Compose providers and activate native Quadlet units, so it needs an
explicit migration plan, rollback evidence, and user approval before
implementation.

## Decision

No backend change was made. Pvl remains deliberately pinned to Compose until the
blocker inventory above is resolved under an approved migration.

## Validation

- `git grep -n 'backend =' abird/master -- hosts` found no explicit Compose pins
  in Abird; `lib/stacks/**` likewise sets none.
- `lib/podman-compose/**` is byte-identical between Pvl `master` and
  `abird/master` (parity audit, 2026-09-22).
- Blocker paths were verified against the compiler's allowed-key and validation
  lists in `lib/podman-compose/quadlet-compiler.py`.
- No files outside this note and the documentation index were changed; no
  deploy, restart, image pull, or live mutation was performed.
