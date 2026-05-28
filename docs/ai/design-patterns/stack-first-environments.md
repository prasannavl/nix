# Stack-First Environments

## Scope

Use this pattern when adding or refactoring multi-environment infrastructure,
service registry data, internal DNS, deployment inventory, package-backed
service modules, or stack-scoped secrets.

Core rules:

- Runtime host modules consume the injected current `stack`.
- Cross-stack systems consume injected `stacks`.
- Standalone package evaluation consumes the stub package stack from
  `lib/flake/stack/package.nix`.
- Normal service modules must not import a concrete runtime stack directly.

## Stack Definition

A stack is one deployable environment. Production uses the bare stack name.
Non-production environments should add a suffix.

Each concrete stack should carry:

```nix
{
  stackName = "pvl";
  org = "pvl";
  env = "prod";
  publicDomain = "p7log.com";
  internalDomain = "pvl.internal";

  users = ...;
  userSets = ...;
  groupSets = ...;

  secrets = {
    services = ...;
    nats = ...;
    postgres = ...;
    nginx = ...;
    vmstack = ...;
  };

  registry = {
    roles = ...;
    services = ...;
    dns = ...;
  };
}
```

`lib/stacks/default.nix` is the stack registry. It exposes concrete stack
profiles plus `all`, which is aggregate metadata for cross-stack consumers, not
a deployable runtime stack.

## Service Registry

The service registry belongs inside each stack:

```nix
stack.registry.roles.<role>
stack.registry.services.<service>
stack.registry.dns.records
```

Generated views should come from `stack.registry`:

- internal DNS records
- split-horizon public DNS records
- nginx upstreams and vhosts
- Cloudflare Tunnel ingress
- host firewall allow rules
- service environment defaults
- deploy inventory
- operator docs and eval outputs

Do not let individual services hand-author divergent copies of hostnames,
private addresses, public vhosts, tunnel targets, and deploy targets.

## Package Boundary

Package `default.nix` files that need service defaults should accept `stack` as
an argument and default to `lib/flake/stack/package.nix`. Host-owned module
evaluation rehydrates package-backed modules with the current injected runtime
stack.

Child package flakes should stay thin and use
`lib/flake/stack/package.nix`.mkFlakeOutputs.

## Deferred Consumers

Port stack-aware secret recipient policy, nginx ingress composition, concrete
service registry data, and app-specific service callers in separate units. This
foundation should be eval-only unless a host or service explicitly opts into a
derived view.
