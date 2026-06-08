# Gap3 Unit 5 Stack Secrets Port 2026-05

## Scope

Unit 5 ports the generic stack-aware secret abstraction shape from upstream
`7dcfbd28` into the local post-`8314da5b` port series.

The local repo currently has only the concrete `pvl` stack plus aggregate `all`,
so this port does not add Abird or Gap3 stack secret trees, recipient values,
host imports, or encrypted secret paths.

## Ported

- `lib/flake/stack/lib.nix` exposes `stack.secrets.base`,
  `stack.secrets.service "<name>"`, `stack.secrets.ext "<provider>"`,
  `stack.secrets.ca`, `stack.secrets.acme`, and the existing named shared family
  bases for NATS, Postgres, VM stack, and nginx.
- `lib/flake/service-module.nix` exposes `stack.srv.mkSecret`,
  `mkServiceSecretPath`, `mkServiceKeySecretPath`, `mkServiceSecret`, and
  `mkServiceSecrets` so runtime `age.secrets` entries can inherit stack-owned
  owner, group, and mode defaults.
- `data/secrets/pvl/default.nix` owns the existing local `pvl` service recipient
  policy while preserving the current evaluated `data/secrets/default.nix`
  output.
- `data/secrets/default.nix` remains the merge surface for global policy and
  imports the local `pvl` stack policy.

## Skipped

- Upstream Abird and Gap3 recipient modules and secret paths from `7dcfbd28` are
  project-specific and intentionally not imported.
- Upstream host runtime module rewrites from `7dcfbd28` are skipped because this
  unit owns only the shared stack/secrets abstraction and docs.
- Applicable parts of `7d8b813b` are skipped: this repo has no local
  `lib/kanidm` or `lib/stalwart` trees to move into `lib/services/`.

## Validation Contract

When splitting `data/secrets/default.nix`, compare the evaluated policy against
`master:data/secrets/default.nix` with Nix evaluation of attrsets or generated
JSON. Do not read or decrypt `data/secrets/**/*.key` contents.
