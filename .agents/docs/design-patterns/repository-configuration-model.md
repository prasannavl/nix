# Repository Configuration Model

## Vocabulary

Use these terms consistently:

- A **configuration family** groups related stack definitions, scopes,
  projection fragments, and optional fabric policy under one `config/<family>/`
  directory. The repository manifest calls this authoring input `families`;
  evaluated consumers do not receive the declarations.
- A **stack definition** is concise authored input under
  `config/<family>/stacks/<stack>.nix`.
- A **stack** is an evaluated deployable configuration produced from a stack
  definition or accepted through the prebuilt-family adapter.
- A **placement** is one substrate realization of a stack, such as the Gondor or
  Nest realization of the `abird` stack.
- A **scope** is the stable selection identity used by projections and operator
  commands. Canonical stack scopes share the stack name; named placement scopes
  such as `abird-gondor` point to one placement.
- An **accounts bundle** is one validated view of users, groups, useful subsets,
  query helpers, and its NixOS account module. Each stack owns its filtered
  bundle; `repository.shared.accounts` is the complete repository-wide bundle
  for stack-independent systems.
- **Shared repository data** is nondeployable cross-stack data exposed as
  `repository.shared`. It is never a stack, placement, or scope.
- An **input set** selects a coherent group of flake inputs for NixOS
  evaluation. A **machine profile** selects VM, Incus VM, or Incus LXC machine
  mechanics. These qualified terms are independent of stacks.

Use the qualified term **configuration family** for the authoring group. Avoid
using family as a synonym for a stack, placement, scope, or runtime owner. Also
avoid `stack profile`, aggregate stack, `stacks.all`, `stacks.shared`, and
`sharedStack`.

## Repository Manifest And Evaluated Contract

`config/default.nix` is the repository manifest. It supplies authored values:

```nix
{
  shared.accounts = import ../lib/flake/accounts { ... };

  families = {
    abird = import ./abird;
    gap3 = import ./gap3;
  };

  modules = { ... };
  defaultScope = "abird";

  nix = {
    substituters = [];
    trustedPublicKeys = [ ... ];
  };
}
```

`lib/flake/repository-config.nix` validates and normalizes that manifest:

```nix
{
  shared = { accounts = ...; };
  stacks = {
    abird = ...;
    "abird-dev" = ...;
    "abird-platform" = ...;
    gap3 = ...;
  };
  fabrics = { abird = ...; };
  scopeDefinitions = ...;
  scopeStacks = ...;
  scopeOwners = ...;
  projections = ...;
  nix = {
    substituters = [ ... ];
    trustedPublicKeys = [ ... ];
  };
}
```

`stacks` is homogeneous: every value is a concrete deployable stack and its key
matches `stack.stackName`. Shared data is separate, so ownership, module,
projection, and deployment code never removes an exceptional `all` value.

A family declaration has the uniform shape
`{ stacks, projectionScopes, projections, fabric ? ... }`. Families may omit a
projection domain; the domain specification supplies its neutral fragment.
Families may declare placement scopes only over their own stacks. The fold does
not re-export raw families or its private stack-to-family index. Consumers use
normalized `scopeOwners` and `fabrics` where those relationships matter.

The repository Nix policy has one purpose: extra binary-cache locations and the
keys trusted by systems in this repository. Deployment inventory contributes the
current local cache URL during root assembly. Repository-specific public keys
remain manifest data; shared `lib/nix.nix` contains only common public caches
and consumes the normalized policy.

## Accounts Contract

Account composition lives under `lib/flake/accounts/`. One accounts bundle has
this public shape:

```nix
{
  users = { ... };       # normalized users keyed by account id
  groups = { ... };      # normalized groups visible to this stack
  userSets = { ... };    # active and explicitly disabled views
  groupSets = { ... };   # membership sets and group queries
  helpers = { ... };     # reusable account predicates and key accessors
  meta = { ... };        # bundle selection metadata
  nixosModule = { ... }; # standard NixOS module function
}
```

`lib/flake/stack/lib.nix` creates `stack.accounts` with the stack's account
filter. `config/default.nix` creates `repository.shared.accounts` with all
stacks included. `mkNixosSystem` validates and selects exactly one bundle:

```nix
accounts =
  if stack == null
  then repositoryConfig.shared.accounts
  else stack.accounts;
```

NixOS and Home Manager receive that selected bundle as the top-level `accounts`
special argument. Modules therefore consume `accounts.users`, `accounts.groups`,
or `accounts.helpers` directly. They do not repeat the stack-or-shared fallback
and do not reach through `repository` for the selected view. Account
deactivation imports `accounts.nixosModule`; explicit user and service modules
own active account creation.

## Authoring Layout

Repository-owned configuration lives under:

```text
config/
  default.nix
  abird/
    default.nix
    stacks/
      abird.nix
      abird-dev.nix
      abird-platform.nix
    placements/
    moves/
    incus-remote.nix
    registry.nix
  gap3/
    default.nix
```

`lib/flake/configuration-family.nix` validates stack definitions and builds the
standard fabric, registry, placement, dependency, access, secret, and account
views. `lib/flake/prebuilt-configuration-family.nix` adapts already-evaluated
stacks. `lib/flake/stack/build-set.nix` is the lower-level stack constructor.

The filename or attribute key is the stack identity. The family builder derives
`stackName` and rejects an authored duplicate. A family authors its secret
namespace once; stack definitions may add `secretScope` but cannot replace it.

`projection-repository.nix` owns the repository path convention. A family
creates one `mkFamilyLayout` from its `config/<family>` root, family name, and
authored placement-scope names. That layout imports stacks, placements, and
moves and also derives the paths exposed to the publisher. Configuration must
not pair an arbitrary fragment directory with a projection scope separately.

Pure family-specific models consumed by more than one outer subsystem also
belong under `config/<family>/`. For example, Abird's Incus remote-project and
certificate model is shared by host construction and secret-recipient policy.
`data/secrets/default.nix` remains the repository-wide recipient orchestrator;
it passes common inputs once to `data/secrets/<family>/`, and that family
composer owns its scoped variants and family-specific derived secrets. Generic
secret path and recipient helpers remain under `lib/flake` and do not absorb
repository topology.

## NixOS Construction

Every deployable host chooses its stack explicitly in `hosts/default.nix`:

```nix
mkNixosSystem {
  hostName = "gap3-gondor";
  stack = stacks.gap3;
  modules = [ ./gap3-gondor ];
}
```

There is no default stack. A missing stack on a deployable host is a wiring bug,
and an implicit repository default would hide it. `defaultScope` is operator
selection policy only; it never supplies `mkNixosSystem.stack`. Its evaluated
form is `{ scope, stack; }`; publication ownership stays independently derivable
from `scopeOwners`.

Stack-independent systems such as base images and installers omit `stack` and
receive `stack = null`. They receive the complete shared accounts bundle.

NixOS receives one selected stack, one selected accounts bundle, and one
explicit repository context:

```nix
{
  stack = effectiveStack; # concrete stack or null
  accounts = selectedAccounts;
  repository = {
    shared = repositoryConfig.shared;
    stacks = effectiveStacks;
    fabrics = repositoryConfig.fabrics;
    inventory = nixbotInventory;
    nix = {
      substituters = [ ... ];
      trustedPublicKeys = [ ... ];
    };
  };
}
```

A normal runtime module consumes `stack`. An account-aware module consumes
`accounts`. A controller or other cross-stack integration uses
`repository.stacks`, `repository.fabrics`, or `repository.inventory`.
Repository-wide data that is not selected per system remains under
`repository.shared`. Nix configuration consumes `repository.nix`. Do not inject
a second top-level `stacks` argument beside `stack`.

Internally, root assembly uses names that identify evaluation stages:

- `canonicalStacks` are the normalized stacks passed to deployment inventory;
- `scopeStacks` includes canonical and declared placement scopes;
- `effectiveScopeStacks` includes projection effects; and
- `effectiveStacks` materializes the final canonical stacks passed to systems.

Nixbot inventory receives only `{ stacks = canonicalStacks; }`, because
inventory defines deployment facts and must not depend on runtime projection
effects.

Input selection uses `inputSet` and `inputSets`; virtualization mechanics use
`machineProfile` and `machineProfiles`. Their qualified names make their roles
clear without overloading `profile` as a synonym for stack.

## Stack, Placement, And Scope Examples

- `abird`, `abird-dev`, `abird-platform`, and `gap3` are stacks.
- `stacks.abird.placements.gondor` and `.nest` are placements of `abird`.
- `abird-gondor` and `abird-nest` are scopes selecting those placements.
- `gap3-gondor`, `gap3-rivendell`, and `llmug-rivendell` are host names, not
  stacks or scopes.

`hostManager.stacks` contains only effective concrete stacks.
`hostManager.scopes` contains canonical stack scopes and declared placement
scopes.

## Service And Infrastructure Ownership

The service registry belongs to the concrete stack. It owns roles, services,
domains, logical endpoints, DNS, and migration metadata. Host and deploy
inventory owns transport endpoints and parent relationships.

Incus projects, networks, secrets, and outbound connector policy remain
stack-scoped. Placement changes select a realization of that policy without
creating a new stack identity. Runtime modules derive addresses and service
roles from the selected `stack`; cross-stack controllers consult
`repository.stacks` explicitly.

## Pvl Adaptation

Pvl is not stackless. Its repository manifest imports one prebuilt configuration
family from `config/pvl`:

```nix
let
  accounts = import ../lib/flake/accounts {
    stackName = null;
    defaultMailDomain = "invalid.invalid";
    includeAllStacks = true;
  };
in
  import ../lib/flake/repository-config.nix {
    shared.accounts = accounts;
    defaultScope = "pvl";
    families.pvl = import ./pvl;
    modules.repo.abird-host-agent = ../lib/services/abird-host-agent;
    nix.trustedPublicKeys = [ ... ];
  }
```

`config/pvl/default.nix` adapts the already-evaluated `pvl` and `pvl-dev` stacks
through `prebuilt-configuration-family.nix`. Their definitions and registry live
under `config/pvl/`; repository-authored stacks do not live under the shared
`lib/` tree.

The shared account bundle replaces the former nondeployable `all` stack.
`repository.stacks` therefore contains only the concrete `pvl` and `pvl-dev`
stacks.

Pvl hosts already choose `stacks.pvl` explicitly. Images and installers are
stack-independent and receive the shared account bundle. `defaultScope =
"pvl"`
preserves unqualified operator lookup while remaining separate from host stack
selection.

A deployment root must declare at least one configuration family and stack. The
family supplies the authoring partition; scope ownership determines repository
paths, and stack identity determines runtime policy. Package-only and isolated
library consumers can remain familyless and stackless through
`lib/flake/default.nix` without constructing the deployment root.
