# service-lib gap3 instantiation

- Date: 2026-04-13
- Scope: `lib/flake/service-module.nix`, `lib/flake/gap3.nix`,
  `lib/flake/stack.nix`, `lib/flake/default.nix`, `pkgs/**/default.nix`,
  `hosts/gap3-rivendell/services/nats.nix`

## Decision

Split the service/client helper layer into:

- a generic factory in `lib/flake/service-module.nix`
- a repo-specific stack instantiation in `lib/flake/stack.nix`

## Applied shape

- `lib/flake/service-module.nix` no longer hard-codes any `gap3`-specific
  defaults.
- The generic entrypoint is now `mkServiceLib { ... }`, which accepts:
  - identity defaults such as client runtime path, secrets base path, service
    identity suffix, and secret owner/group/mode
  - transport defaults such as PostgreSQL and NATS URLs and CA paths
- The broader parity shape also includes shared secret-owner defaults
  (`defaultSecretOwner`, `defaultSecretGroup`, `defaultSecretMode`), optional
  external-service identity defaults, and family-specific secret-base helpers
  for integrations such as NATS or PostgreSQL.
- `lib/flake/stack.nix` instantiates that factory as `srv` with the current repo
  defaults:
  - service identity suffix `srv.z.p7log.com`
  - non-service client identity suffix `p7log.com`
  - shared agenix runtime path `/run/agenix`
  - repo client-identity secrets under `data/secrets/services/<name>/` using
    `client.crt.age` and `client.key.age`
  - default non-service client secret ownership `pvl:pvl`
  - local PostgreSQL and NATS connection defaults rooted on `127.0.0.1` plus
    `/run/agenix/pvl-ca-cert`
- `srv.mkIdentity` now defaults suffix and secret ownership from the
  instantiated environment and accepts `pname` as the package-facing default
  name input, so package call sites can normally use one local `pname` source of
  truth instead of repeating identity suffix and owner/group details.
- `srv.mkIdentity` now accepts either direct identity inputs
  (`srv.mkIdentity { ... }`) or a package derivation directly
  (`srv.mkIdentity build`). When called with a derivation, it derives the client
  identity from `build.pname`, so package files do not need a second local
  `pname` or `id` binding outside the actual derivation boundary.
- The derivation-returned identity is callable for overrides, so
  `srv.mkIdentity build { ... }` also works when a package needs small
  deviations from the instantiated defaults.
- `srv.mkIdentity` now also exports a tiny `nixosModule` that materializes its
  `age.secrets`, so package-owned client identity secret wiring can be consumed
  as a package-provided module fragment instead of being re-declared in
  transport-specific host modules.
- Compatibility aliases `srv.mkClientIdentity` and `srv.mkClientIdentityFor`
  remain available when the older naming is already used.
- The root flake now auto-materializes `age.secrets` for installed packages that
  export `passthru.clientIdentity`, via a shared `clientIdentityModule`. That
  keeps client identities aligned with the host's installed package set without
  transport-specific or host-specific import lists.
- `srv.mkIdentityFor drv { ... }` is kept as the explicit derivation-based alias
  when that spelling is clearer at the call site.
- Package and host call sites should import `stack.nix` and use `stack.srv`, not
  import `service-module.nix` directly for repo-local work.
- `stack.nix` also re-exports the shared package helper as `stack.pkg`, so
  package definitions can use one repo-local helper import and commonly alias:
  - `pkg = stack.pkg`
  - `srv = stack.srv`
- `lib/flake/default.nix` re-exports both:
  - `stack`
  - `serviceModuleFactory`
- `lib/flake/default.nix` keeps `servicePlatform = stack`, `gap3 = stack`, and
  `serviceModule = stack.srv` as compatibility aliases.

## Why

- The generic helper layer is reusable outside any one environment.
- Repo-local defaults live in one obvious instantiation file instead of being
  embedded across helper internals.
- Future environments can instantiate their own service/client libraries without
  forking the shared helper implementation.
