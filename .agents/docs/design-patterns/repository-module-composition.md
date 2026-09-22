# Repository Module Composition

## Scope

Use this pattern when a repository or one of its stacks must compose a generic
package-owned NixOS module with repository-specific policy. It provides one
declarative root boundary without turning `extraCommonModules` into an
unstructured list of package adapters.

## Contract

The root flake passes one repository-owned registry:

```nix
repoModules = import ./lib/stacks/modules.nix;
```

`lib/stacks/modules.nix` contains module paths only:

```nix
{
  repo.abird-host-agent = ../services/abird-host-agent;

  stacks.gap3.chat-intelligence-nats-streams =
    ../../pkgs/support/nats-streams/chat-intelligence.nix;
}
```

`repo` contains modules that are safe to evaluate for every system assembled by
the repository. `stacks.<stackName>` contains adapters that are evaluated only
for that concrete stack. Keep the registry declarative: do not put inline
modules, package results, root outputs, or condition functions in it.

Do not put module paths or functions in `lib/stacks/default.nix` or concrete
stack values. Stack profiles remain data-shaped because service placement,
host-management, serialization, and cross-stack consumers inspect them as data.

## Canonical selection

The shared root resolves repository modules inside `mkNixosSystem`, after it has
resolved `effectiveStack`. Composition is:

```text
attrValues repoModules.repo
++ attrValues repoModules.stacks.${effectiveStack.stackName}
```

Use the canonical `stack.stackName`, never a host name, placement name, or the
attribute key used by a caller. Placements therefore inherit the module set of
their owning stack.

A call with no stack receives repository modules only. The aggregate `all` stack
also receives repository modules only; stack-specific modules for `all` are
forbidden. Repository modules precede selected stack modules for stable
diagnostics, but list order is not an override mechanism. Modules must express
precedence with the NixOS module priority functions.

## Ownership layers

- A generic package and its generally safe module remain in the package's
  `default.nix` and `passthru.nixosModule`. The package manifest registers the
  generic package, not a repository-specific specialization.
- `lib/stacks/modules.nix` owns repository and stack registration only.
- A registered adapter owns repository- or stack-specific composition of the
  generic package facility.
- Host modules own service enablement. Registration must not silently enable a
  service unless enabling it is itself an explicit stack-wide policy.

Package-owned generic modules may continue to be available to every host.
Repository and stack adapters must enter through `repoModules`, not through a
growing `extraCommonModules` argument.

## NATS stream-set example

Both repositories register the generic `pkgs/support/nats-streams/default.nix`
package. The shared default owns the stream-set factory and standard NATS
service behavior.

Abird registers `pkgs/support/nats-streams/chat-intelligence.nix` under
`stacks.gap3`. That adapter uses the shared factory with Chat Intelligence
streams, bridge routes, secrets, and unit policy. Other stacks do not evaluate
that adapter. The Gap3 host remains responsible for enabling the resulting
service.

Additional stream sets, or adapters for unrelated packages, follow the same
rule: add the adapter path to the owning stack in `lib/stacks/modules.nix`. They
do not require another root-flake argument or another global common-module
entry.

The generic stream-set ensure unit owns creation, not destructive migration. An
existing stream must match its declared subject, file storage, work-queue
retention, and maximum-consumer contract. Drift fails closed with the observed
configuration so an operator can reconcile data-bearing stream changes
explicitly. Creation is allowed only after a successful JSON stream listing
establishes absence; authentication, transport, malformed responses, and other
lookup failures stop without mutation.

## Validation

The shared resolver must fail closed:

- Accept only the top-level `repo` and `stacks` fields.
- Require `repo` and every `stacks.<name>` value to be named attribute sets of
  existing module paths.
- Reject inline functions, inline module attrsets, derivations, and missing
  paths.
- Require every declared stack key to exist in the canonical stack profile
  registry, and reject an `all` entry.
- Require every explicitly supplied runtime stack to have a known
  `stack.stackName`.
- Reject duplicate logical names between `repo` and a stack, and reject a module
  path registered more than once anywhere in the registry.
- Select modules in sorted logical-name order for deterministic evaluation and
  diagnostics.

Tests must cover repository-only selection, exact stack selection, aggregate
selection, placement-to-stack selection, cross-stack non-leakage, unknown stack
names, unsupported fields, missing paths, and duplicate paths. Repository tests
must additionally prove that stack-specific options appear only on their
intended stacks and that existing generated services retain their package,
environment, secrets, and systemd semantics.

## Evaluation and cycle boundaries

Registry entries are paths so selecting them does not evaluate packages or flake
outputs. The root supplies adapters with `repoModulePkgs`, `stack`, `stacks`,
`inputs`, and `system`. `repoModulePkgs` is computed from the selected flake
profile's nixpkgs input and overlays, so composition uses the same package
universe without depending on a root output.

Use `repoModulePkgs` when an adapter must construct a package-specialized
module. The ordinary NixOS `pkgs` argument comes from `config._module.args`;
forcing it while the module system is still collecting imports or option shape
creates a configuration fixed-point recursion. Host modules may still extend
`nixpkgs.config` later, so adapters should keep their composition-time package
requirements profile-owned and explicit.

Adapters must not reference `packageOutputs`, `rootLib.nixosModules`,
`nixosConfigurations`, or another root flake output. Those references can form a
root-output cycle or bind a service to the flake evaluation system instead of
the consuming host. Avoid importing a generic package-owned module twice; an
adapter should instantiate a distinct specialization from the generic factory.

## Migration and future consolidation

Introduce `repoModules` as the single module-composition argument, migrate the
current `extraCommonModules` caller into `lib/stacks/modules.nix`, and then
remove `extraCommonModules`. Keep manifests pointed at generic package defaults
while moving repository specializations into registered adapters.

If root repository inputs are later consolidated, move the same value without
changing its schema:

```nix
repositoryConfig.modules = import ./config/modules.nix;
```

During that transition, `repoModules` may be a temporary compatibility alias for
`repositoryConfig.modules`, but there must be only one effective source of
module composition. Reject configurations that define both independently.
