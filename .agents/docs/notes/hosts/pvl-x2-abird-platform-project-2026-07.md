# pvl-x2 Abird Platform Project, 2026-07

## Decision

The existing contents of outer projects `abird`, `abird-dev`, and `abird-stage`
are explicitly disposable. After that reset, `pvl-x2` declares three clean Abird
projects:

- `abird-platform` on `10.10.0.0/24`;
- `abird` on `10.10.100.0/24`;
- `abird-dev` on `10.10.220.0/24`.

`abird-stage` remains retired and is not recreated.

The platform project owns a fresh parent-managed `abird-nest` at `10.10.0.10`.
The nested Nest controller later creates fresh `abird-ci` at `10.10.0.80` in the
same project. There is no migration, copy, or `adopt` path from an old guest.
The `abird` and `abird-dev` projects deliberately contain no declared instances
until their later application migrations are ready.

The complete `abird-gondor` stack is outside the deletion scope. It remains
nested below the `gap3-gondor` guest in the parent `default` project.

## Parent Topology Surface

`hosts/pvl-x2/incus.nix` keeps one compact `abirdTopology` declaration for all
three subnet octets, platform instance octets, and outbound `network.allow`
relationships. Local normalization feeds the narrow result to
`incusLib.mkManagedFabricPolicy`.

The platform fabric uses the `containedPublic` baseline and has one cross-fabric
exception:

- `abird-platform` may reach `default` destination `10.10.30.20` on TCP/UDP 53
  for the preserved Gondor DNS proxy.

No broad `forwardTo` grant is used. The empty application fabrics have no
cross-project exceptions. Each project has its own bridge, pool, default
profile, and certificate delegation. The fresh Nest receives all three
delegation paths, but its z-side remote manager initially declares only
`abird-platform`, so no application guest can be created from current desired
state.

## Destructive Transition Boundary

Removing projects from Incus preseed does not delete their live contents or
their global bridge/pool resources. The reset is therefore an explicit operator
gate, not permanent migration machinery in `hosts/pvl-x2/incus.nix`.

Before any mutation, capture and review:

- every instance and custom volume in projects `abird`, `abird-dev`, and
  `abird-stage`;
- every profile and certificate restriction referencing those projects;
- bridge users for `iabirdbr0`, `iabirdbr1`, and `iabirdbr2`;
- pool users for `abird`, `abird-dev`, and `abird-stage`;
- the separate nested Gondor inventory, proving it is reached through
  `default/gap3-gondor` and is not among the targets.

After explicit approval of that readback, delete the three projects with their
contents. Only then, and only after confirming zero remaining references, delete
the three legacy bridges and pools. Never target `default`, `pvl`,
`abird-platform`, `incusbr0`, `ipvlbr0`, `iabirdplatbr0`, or their pools.

The intended destructive command set, run manually after the audit gate, is:

```bash
incus project delete --force abird
incus project delete --force abird-dev
incus project delete --force abird-stage

incus network delete iabirdbr0
incus network delete iabirdbr1
incus network delete iabirdbr2

incus storage delete abird
incus storage delete abird-dev
incus storage delete abird-stage
```

Stop on any failure and re-read remaining resource users before proceeding; do
not turn this into a loop or an activation-time cleanup.

Deploy the parent configuration after cleanup. It recreates empty `abird` and
`abird-dev` projects and creates the fresh platform fabric and Nest without
transitional access or adoption metadata. Fresh Tailscale enrollment and SSH
identity must be validated before the nested platform deployment proceeds.

No live Incus mutation or deployment was performed while preparing this change.

## Preparation Validation

Evaluation currently renders:

- projects: `pvl`, `abird-platform`, `abird`, `abird-dev`;
- networks: `incusbr0`, `ipvlbr0`, `iabirdplatbr0`, `iabirdbr0`, `iabirdbr2`;
- pools: `default`, `pvl`, `abird-platform`, `abird`, `abird-dev`;
- certificate delegations: `pvl`, `abird-platform`, `abird`, `abird-dev`;
- parent platform instances: only `abird-nest`;
- parent application instances: none;
- preseed migrations: none;
- platform access: only Gondor DNS at `10.10.30.20` on TCP/UDP 53.

The full `pvl-x2` NixOS build and repository diff lint gate passed.
