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

Concrete stack registry files should stay data-shaped. Prefer a small stack
function that defines fixed `base` metadata and stack `data`, then finishes with
one `mkStackRegistry (stack // base // data)` call. Keep normalization,
placement derivation, endpoint policy wiring, and generated registry views in
the shared service-registry library.

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

Do not let individual services hand-author divergent copies of domains, private
addresses, vhosts, tunnel targets, and deploy targets.

Within stack definitions, group service specs under the role that owns them.
Service specs may reference domain groups by stable key or by domain object.
Normalize those refs only at the registry boundary:

```nix
corp = {
  zulip = {
    domain = "zulip";
  };
}
```

Prefer domain refs in tunnel domain lists. Keep raw strings only for literal
hostnames that are not already modeled in `domains`:

```nix
tunnelDomains = with domains; [apex auth docs];
```

## Outbound Connectors

Stacks should expose singleton outbound side-effect policy through
`stack.enableExternalConnectors`.

Use `stack.enableExternalConnectors` for services that initiate external or
cross-placement effects with a stack identity:

- persistent connectors such as Cloudflare Tunnel and the dialing side of
  WireGuard edge links
- event consumers such as Telegram, Zulip, Slack, Discord, or webhook bots
- mail egress through public SMTP or third-party relay providers
- external pollers that spend shared API quota or mutate external state

Keep `stack.tunnels` as transport configuration data. It should describe tunnel
ids, credential filenames, subnets, ports, and endpoint addresses; it should not
carry the policy decision for whether this placement may connect.

Do not use placement alone as permission to run these connectors. A standby
placement can run internal services and expose node endpoints while its outbound
connectors remain disabled. The active endpoint group is the default service
placement for active role names and public DNS records; individual service specs
may pin `placement` when a service intentionally lives on another endpoint
group. `enableExternalConnectors` controls whether the placement may initiate
singleton outbound behavior.

Keep active service addresses separate from local instance addresses. A standby
or delegated placement can run the same service module without becoming the
active service target. For example, CoreDNS records should answer from the stack
service registry and respect role endpoint overrides, but the CoreDNS `bind`
address must come from the local endpoint group for the proxy instance being
built. Use `dns.activeResolverAddress` for DNS clients that should follow the
active stack endpoint, and `dns.localResolverAddress` for services binding on
the local placement. Do not use the active split-horizon resolver address as a
local listen address on non-active proxy placements. When a stack has multiple
endpoint groups, derive its concrete `placements` from `endpointGroups` so
subnet ownership and local placement identity share one source of truth. Put
endpoint-local role address overrides under
`endpointGroups.<group>.roles.<role>` instead of maintaining a separate override
map.

Concrete stack profiles should turn outbound connectors on only after the stack
has its own scoped credentials, domains, routes, and external identities.

## DNS Model

Use stack-scoped internal DNS zones:

```text
abird.internal
gap3.internal
```

Service names should represent service or role identity:

```text
corp.abird.internal
data.abird.internal
id.abird.internal
stalwart.abird.internal
```

Concrete node names may exist for operators and cutovers:

```text
abird-corp.pvl-x2.abird.internal
abird-corp.gondor.abird.internal
abird-corp.dev.abird.internal
```

Public protocol identities remain public names:

```text
zauth.abird.ai
zdocs.abird.ai
zstalwart.abird.ai
```

Do not replace OIDC issuers, callback URLs, cookie domains, or user-facing URLs
with `.internal` names. Use split-horizon DNS and internal edge routing when
trusted clients need the public protocol identity without leaving the private
network.

When adding a new public hostname behind shared edge auth, treat the identity
provider callback registration as part of the same endpoint change. For
`oauth2-proxy`-style shared clients, the callback is normally
`https://<public-host>/oauth2/callback`; add it for every protected hostname. Do
not rely on an already-authenticated browser to validate the route: test or
inspect the fresh unauthenticated login start so missing callbacks fail before
deploy.

## Incus Model

Incus project ownership is stack-scoped.

`abird-nest` is a controller host that can manage multiple Abird stack projects;
it is not itself the stack:

```nix
stacks.abird.infrastructure.incus.project = "abird";
stacks."abird-stage".infrastructure.incus.project = "abird-stage";
stacks."abird-dev".infrastructure.incus.project = "abird-dev";
```

Eventually, controller-host Incus config should be generated from the concrete
stack registry instead of hard-coded project, subnet, and instance copies.

## Secrets Model

Secrets should become stack-scoped over time:

```nix
stack.secrets.base
stack.secrets.nats
stack.secrets.postgres
stack.secrets.nginx
stack.secrets.vmstack
```

Existing `default*SecretsBasePath` fields can remain as compatibility exports
while service modules migrate to `stack.secrets.*`.

`data/secrets/default.nix` remains a cross-stack recipient view. It may use
`stacks.all` for user metadata and may iterate concrete stacks for stack-owned
machine/service recipients.

## Rollout Plan

1. Establish stack identity.
   - Keep production as the bare brand stack, such as `abird` and `gap3`.
   - Use suffixes only for non-production stacks, such as `abird-stage` and
     `abird-dev`.
   - Add `org` and `env` to concrete stack profiles.

2. Keep host stack threading.
   - Host declarations choose the concrete stack once.
   - NixOS modules receive `stack` and `stacks` through `specialArgs`.
   - Runtime modules consume `stack`.

3. Introduce stack-local registry data.
   - Add pure `stack.registry` data with no runtime behavior change.
   - Model roles, services, endpoints, domains, internal names, DNS, and deploy
     views.

4. Generate eval-only views.
   - Expose registry-derived DNS, nginx, tunnel, deploy, and Incus projections
     as pure values first.
   - Compare generated values with current hand-authored config.

5. Move low-risk consumers.
   - Start with nginx input constants and Cloudflare Tunnel ingress.
   - Then move service-to-service callers that can keep rendering the same
     addresses.

6. Deploy internal DNS.
   - Start with static generated records.
   - Add host resolver config for trusted networks.
   - Add split-horizon public names only for protocol identities that need them.

7. Generate Incus and deploy inventory.
   - Generate controller-host Incus projects/instances from stacks.
   - Generate nixbot targets from stack registry deploy views.
   - Keep cross-stack deploy controllers explicit.

8. Migrate secrets to stack paths.
   - Add `stack.secrets`.
   - Move service modules from `default*SecretsBasePath` to stack-scoped
     secrets.
   - Keep compatibility fields until all consumers move.

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
