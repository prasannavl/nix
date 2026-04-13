# service-lib gap3 instantiation

- Date: 2026-04-13
- Scope: `lib/flake/service-module.nix`, `lib/flake/gap3.nix`,
  `lib/flake/default.nix`, `pkgs/**/default.nix`,
  `hosts/gap3-rivendell/services/nats.nix`

## Decision

Split the service/client helper layer into:

- a generic factory in `lib/flake/service-module.nix`
- a repo-specific `gap3` instantiation in `lib/flake/gap3.nix`

## Applied shape

- `lib/flake/service-module.nix` no longer hard-codes any `gap3`-specific
  defaults.
- The generic entrypoint is now `mkServiceLib { ... }`, which accepts:
  - identity defaults such as client runtime path, secrets base path, service
    identity suffix, and secret owner/group/mode
  - transport defaults such as PostgreSQL and NATS URLs and CA paths
- `lib/flake/gap3.nix` instantiates that factory as `srv` with the
  current `gap3` defaults:
  - service identity suffix `srv.gap3.ai`
  - non-service client identity suffix `gap3.ai`
  - shared agenix runtime path `/run/agenix`
  - repo secrets under `data/secrets/nats/clients`
  - default non-service client secret ownership `gap3:gap3`
  - `gap3` PostgreSQL and NATS connection defaults
- `srv.mkClientIdentity` now defaults suffix and secret ownership from the
  instantiated environment and accepts `pname` as the package-facing default
  name input, so package call sites can normally use one local `pname` source
  of truth instead of repeating identity suffix and owner/group details.
- `srv.mkClientIdentity` now accepts either direct identity inputs
  (`srv.mkClientIdentity { ... }`) or a package derivation directly
  (`srv.mkClientIdentity build`). When called with a derivation, it derives the
  client identity from `build.pname`, so package files do not need a second
  local `pname` or `id` binding outside the actual derivation boundary.
- The derivation-returned identity is callable for overrides, so
  `srv.mkClientIdentity build { ... }` also works when a package needs small
  deviations from the instantiated defaults.
- `srv.mkClientIdentityFor drv { ... }` is kept as the explicit derivation-based
  alias when that spelling is clearer at the call site.
- Package and host call sites should import `gap3.nix` and use `gap3.srv`, not
  import `service-module.nix` directly for repo-local
  work.
- `gap3.nix` also re-exports the shared package helper as `gap3.pkg`, so
  package definitions that already depend on `gap3` can use one repo-local
  helper import and commonly alias:
  - `pkg = gap3.pkg`
  - `srv = gap3.srv`
- `lib/flake/default.nix` re-exports both:
  - `gap3`
  - `serviceModuleFactory`
- `lib/flake/default.nix` also keeps `serviceModule = gap3.srv` as a
  compatibility alias.

## Why

- The generic helper layer is now reusable outside `gap3`.
- Repo-local defaults live in one obvious instantiation file instead of being
  embedded across helper internals.
- Future environments can instantiate their own service/client libraries
  without forking the shared helper implementation.
