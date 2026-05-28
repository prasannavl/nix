# Gap3 Unit 4 Stack Registry Foundation

## Scope

Unit 4 of the selective post-`8314da5b` Gap3 port covers reusable stack,
service-registry, and package helper foundations only.

Ported generic foundations:

- `lib/flake/service-registry.nix` for pure role, endpoint, DNS, service port,
  and URL projections.
- `lib/flake/stack/lib.nix` for stack profile construction around
  `service-module.mkServiceLib`.
- `lib/flake/stack/users.nix` and `user-data-lib.nix` for stack-aware user and
  group projection.
- `lib/flake/stack/package.nix` for standalone package evaluation and thin
  child-flake wrappers.
- `lib/stacks/default.nix` and `lib/stacks/pvl.nix` as the local repo stack
  registry.
- NixOS `specialArgs.stack` / `specialArgs.stacks` threading for host and
  package-owned module evaluation.

## Deferred

- Do not port Abird host trees, role addresses, DNS values, service registry
  service data, or concrete stack users in this unit.
- Keep stack-aware secret recipient policy from `7dcfbd28` and `7d8b813b` for
  the next unit.
- Keep nginx ingress composer work from `83506a27` for the later nginx unit.
- Skip the mail-directory projection from `f93b23d9` here; only the generic
  group directory data shape was ported.
- Skip `e89ebb21` because `pkgs/support/nats-http-bridge` is not present in the
  local checkout.

## Local Shape

`lib/flake/stack.nix` remains as a compatibility import for the local `pvl`
stack. Runtime hosts choose `stacks.pvl` through `hosts/default.nix`; standalone
package and child-flake evaluation uses the stub `package` stack.
