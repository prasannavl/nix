# Abird Context and Component Boundaries

## Public contexts

Abird has exactly three user-facing contexts:

| Context | Owns                                                                             | Must not own                  |
| ------- | -------------------------------------------------------------------------------- | ----------------------------- |
| `pkgs`  | Nixpkgs package set, overlays, low-level `pkgs.toolchains` backing seam          | deployment policy             |
| `ab`    | portable build/package/task/NixOS APIs plus explicitly bound reusable components | deployment `stack`            |
| `stack` | deployment identity, topology, secrets, endpoints, network/tunnel policy         | portable package construction |

A core-only `ab` exposes:

```text
ab.build
ab.flake
ab.nixos
ab.package
ab.tasks
ab.toolchains
```

Optional component bindings add:

```text
ab.runtime
ab.services
ab.system
ab.repo
```

There is no public `ab.service` or `ab.stack` namespace. The deployment `stack`
remains a separate value.

## Component graph

The reusable component graph is intentionally one-way.

Shared structural validation lives on the `ab-core` component object as
`core.validation` / `core.validationPaths`. Portable package-flake composition
lives on the same component object as `core.project`; `core.packageScope` binds
one recursive package-author scope. These helpers support component/repository
composition and do not add namespaces to the portable `ab` value.

Z supplies repository-specific package-composition defaults through
`nix/project.nix`; the core engine itself contains no Z path.

```text
ab-core
  ↑
  ├── ab-runtime
  ├── ab-services
  ├── ab-repo
  ├── ab-stack
  └── ab-system
```

The repository-facing composition entrypoint is simply:

```nix
ab = import ./ab;
```

That static registry pre-wires component dependencies and exposes
`ab.{core,runtime,services,repo,stack,system}`. Repo composition should use this
registry instead of manually importing `ab-core` and then threading it through
every component constructor.

For a concrete package set, bind the reusable runtime/service/system context
once:

```nix
ab = (import ./ab).forPkgs {
  pkgs = pkgs;
  projectRoot = ./.;
  treefmtConfig = ./treefmt.toml;
};
```

NixOS composition passes that bound `ab` as a special argument. Concrete
deployment `stack` remains a separate argument; generic stack algebra stays on
the static registry, not the bound `ab`. Package constructors continue to
receive the narrower package-author context created by `ab-core`, so convenience
at the repo layer does not broaden portable package authority.

A repository-aware registry can be created with
`(import ./ab).withRepository repository` when static repo APIs such as
`packagesFor` are needed. `forPkgs` on that registry also adds the bound
`ab.repo` namespace.

Declared dependencies are:

| Component | Required | Optional |
| --------- | -------- | -------- |
| core      | none     | none     |
| runtime   | core     | none     |
| services  | core     | none     |
| repo      | core     | none     |
| stack     | core     | none     |
| system    | core     | none     |

Runtime capabilities are injected at the adapters that use them, not threaded
through unused component constructor arguments. Normal bound usage stays `ab`.
Static-only composition also uses `ab`. Use `abLib` for the unbound registry
only when both APIs are used in the same scope, such as contract tests. Merely
creating or forwarding a bound value does not require a second local name.

Component source trees are extraction boundaries. A component must not reach
into sibling component source, Z `hosts/`, deployment `config/`, repository
`pkgs/`, `lib/`, `data/`, or `overlays/`. Data needed by a component is passed
through its constructor or fixture inputs.

## Portable package contract

Leaf packages are injectable constructors:

```nix
{
  pkgs,
  ab,
  dependencyA,
  ...
}: ...
```

Rules:

- `pkgs` and `ab` are supplied by composition.
- Repository package dependencies are declared locally in `default.nix` through
  `ab.package.withDeps`.
- A leaf does not discover siblings through `pkgs.<repo-package>` or
  `ab.repo.packages`; dependency resolution stays inside the shared `withDeps`
  helper so root and standalone composition use one context.
- A leaf does not import Nixpkgs, install overlays, construct a new `ab`, or
  create/extend a package set.
- Portable package constructors do not accept deployment `stack`.
- A package that needs a stable deployment identity name may publish only
  neutral metadata such as `identityIntent = { name = build.pname; };`.
- Neutral package identity intent must not contain
  suffix/domain/certificate/key/ secret/runtime-path or secret ownership/mode
  policy.
- Deployment binds package intent through `stack.identity.bind`; the binder
  rejects derivations and policy-bearing attributes.
- Deployment integration wraps an already-built derivation; it must not rebuild
  the package merely to inject stack policy.

The dependency graph is authored once in the package:

```nix
{pkgs, ab, dependencyA ? ../dependency-a}:
ab.package.withDeps {
  inherit dependencyA;
} ({dependencyA}: ...)
```

Explicit derivation overrides remain valid; a constructor may support `null` to
disable optional artifact inheritance without dropping source dependencies.
Defaults still appear once, in the package constructor. `withDeps` resolves only
Nix paths; all other values pass through unchanged and remain lazy. An attribute
named `path` never turns a value into a constructor. To customize constructor
arguments, supply an explicitly constructed dependency derivation.

Composition uses `core.packageScope { pkgs = pkgs; }` for a recursive package
set with a core-only `ab` and coherent `pkgs` / `callPackage`. Root publication,
child flakes, dependency resolution and contextual Rust exports share the same
scope-binding implementation. Contextual build overrides also rebind dependency
resolution; copying `ab.build` alone leaves the old dependency closure attached.
Leaves must not create their own scopes.

The repository manifest contains only publication metadata. Child `flake.nix`
files are mechanical literal wrappers around `nix/project.nix`; they do not
restate dependencies. Nix requires literal top-level flake/input sets, so
standard input declarations remain in the wrapper. `withDeps` resolves nested
constructors using the same bound recursive package set, so root and child-flake
builds share one `pkgs + ab` fixed point.

Publication is declaration, not override: package aliases, tooling exports and
app names must be unique in their respective output namespaces. An alias cannot
shadow a canonical package. Intentional replacement uses the explicit external
package override seam, not accidental attribute-merge precedence.

## Module and policy contracts

- `ab.system.modules.*` entries are ready for NixOS `imports`.
- Parameterized profiles stay outside that module namespace; e.g.
  `ab.system.profiles.mkWmModule { renderDevice = "/dev/dri/custom"; }`.
- Prefer existing NixOS options over factory arguments. Nvidia is a native
  module; select a driver through `hardware.nvidia.package`.
- Shared Nix setup accepts one resolved `cachePolicy`. Trust roots, third-party
  cache defaults, unfree policy, Nix version, GC schedule and installation state
  version belong to repository/host policy. Z binds these in
  `nix/profiles/policy/nix.nix`; state versions never follow release upgrades.

## Stack assembly

Registry and family paths use one namespace-aware finalizer. Registry fields,
projection facts and placement maps have explicit ownership; overlapping
contributions fail instead of silently replacing a namespace. Extensions may add
non-conflicting fields; no generic deep merge decides policy precedence.

Service names are unique across roles. Explicit same-role overrides remain
supported. Projection data cannot replace placement maps or `withServiceRoles`;
role remapping preserves the bound projection and placement view.

## Toolchains

`ab.toolchains` is the package-author resolver namespace. It is backed by the
low-level package-set seam `pkgs.toolchains`.

The uniform language keys are:

```text
deno
go
node
python
rust
```

Ordinary packages use native Nixpkgs builders/runtime packages when the package
set already expresses the required contract. Resolver use is reserved for real
version/provider/compiler identity policy.

Standalone injected `toolchains`, public `*ToolchainFor`, and `craneLibFor` are
not APIs. Lowercase resolver implementation such as `toolchainFor` remains
implementation-only under `ab/core/packaging/**`; path placement does not make
it public. The curated exports from `ab/core/default.nix` define the API
boundary.

## Runtime, services and deployment policy

Runtime components own execution mechanics and neutral runtime facts. Runtime
facts describe resources such as ports, dependencies, units, paths, readiness,
storage and control sockets; they do not carry Nginx routes, tunnel policy or
deployment-specific service intent.

For Podman specifically, lifecycle/compiler/fact mechanics live under
`ab.runtime.podman`. Firewall projection stays runtime-owned, Nginx projection
is service-owned, tunnel projection is stack-owned, and the host-agent adapter
is owned by `ab.services.abirdHostAgent`. `nix/podman.nix` only composes those
APIs. Runtime must never import service/stack/controller policy.

For Incus specifically, lifecycle/module/helper mechanics live under
`ab.runtime.incus`; Incus fabric policy is stack-owned under
`ab.stack.fabric.incus`; Z binds repository-built image defaults through
`nix/incus.nix`. Do not reintroduce a merged Incus compatibility library.

Reusable concrete service semantics live under `ab.services`. Service
renderers/models consume neutral inputs. Z-owned projections join runtime facts
with deployment policy.

For AI specifically, catalog/backend/inference semantics, hosting projection,
the deployment planner, and the reusable NixOS module all live under
`ab/services/ai/**`. The hosting policy is an intentional public component seam
at `ab.services.ai.projection`; cross-owner consumers use that seam rather than
importing implementation files. Z supplies concrete model/backend/stack
declarations. Owner-local AI module/projection tests stay with the component;
real deployment integrations remain under `nix/tests/**`.

Deployment policy remains in `stack` and Z integration, including concrete
secrets, identity, topology, ingress/tunnel intent and host placement.

Reusable tunnel declaration/projection algebra is owned by `ab.stack.tunnels`;
provider/runtime and host-managed planning live under
`ab.runtime.network.tunnels`. Z host composition resolves tracked secrets and
maps neutral managed-unit metadata into the selected controller.

Reusable stack algebra is grouped under `ab.stack`, including `accounts`,
`fabric`, `registry`, `buildSet`, `serviceStack`, `ingress`, `secrets`,
`servicePolicy`, `tunnels`, and `units`.

Reusable stack foundation algebra is owned by `ab.stack.accounts`,
`ab.stack.secrets`, `ab.stack.servicePolicy`, and `ab.stack.units`. Concrete
repository user/group data is injected by Z composition and must not be
default-imported by the component.

`ab.stack.accounts.mk` and `ab.stack.mkBase` require explicit raw user/group
inputs. Z constructs that account-data value once and passes it into repository
and stack composition. This keeps `ab-stack` extractable and prevents hidden
component -> repository-data dependencies.

Canonical concise stack namespaces include:

```text
stack.certs
stack.infra
```

Do not reintroduce the historical `stack.certificates` or `stack.infrastructure`
aliases. Generic domain APIs whose actual concept is "certificates" (for example
Incus trust certificates) keep their domain-native name.

## Repository binding

`ab.repo` is absent from core/runtime/services-only contexts. It appears only
when the repo component is explicitly bound.

Repo binding is lazy: metadata such as `ab.repo.root` can be inspected without
forcing the repository package graph. Package construction happens when
`ab.repo.packages` is demanded.

The `ab-repo` **component object** also owns reusable repository composition
algebra:

```text
repoComponent.cache
repoComponent.config
repoComponent.fold
repoComponent.importDirectory
repoComponent.modules
repoComponent.projections.fold
repoComponent.projections.specifications
```

These are composition APIs, not additions to the bound portable `ab.repo`
namespace. The component object can be imported without a repository binding;
`packagesFor` / `extension` require the concrete repository only when used.

Stack-aware service placement/move repository semantics are composed explicitly:

```nix
repoComponent.projections.services {
  serviceStack = stackComponent.serviceStack;
}
```

This returns `layout`, `placements`, `moves`, `admission`, and `adapters` while
keeping `ab-repo`'s declared dependency graph core-only. The repo component must
never import `ab-stack` directly.

## Z integration

Z is the composition root. It may:

- bind core/runtime/services/repo/system components;
- construct deployment stacks through `ab-stack`;
- project runtime facts into Nginx/tunnel/firewall/host-agent policy;
- wrap portable derivations with `ab.nixos` deployment integration;
- inject repository-owned package implementations into reusable service seams.

Z-owned Nix composition belongs under `nix/**`; concrete host and deployment
data remain under `hosts/**` and `config/**`. Root/output binding, concrete
machine profiles, image selection and repository-specific installer composition
remain Z-owned under `nix/**`; generic config-family, projection/phase and
installer mechanics are reusable component APIs. Repository acceptance tests
that import concrete host or deployment declarations belong under
`nix/tests/**`, even when they exercise reusable service semantics; test-only Z
ownership must not create a residual `lib/services/**` service owner.

Do not move Z-specific orchestration into a portable component merely to
eliminate a directory. Thin Z wrappers that only inject a repository package
default should instead be removed: make the dependency explicit at the Z call
site and keep the reusable service API in its `ab/services` owner.

Package-adjacent NixOS integration is not automatically package-owned. Reusable
service modules belong under their `ab/services/**` owner rather than inside the
package source closure; this keeps package derivations independent of NixOS
integration while preserving extraction boundaries. Repository-specific wiring
stays at host/root composition sites. Generic builder/GC coordination is owned
by `ab/system/nix/gc-coordination.nix`; a host that wants controller integration
binds its exported GC program explicitly.

Phase 14 extends reusable ownership with `ab-system`; Phase 14A establishes the
component with a core-only hard dependency and moves reusable host boot, kernel,
hardware, security, storage, systemd, user, Nix and network mechanisms under it.
Z supplies repository cache, locale and other deployment policy through explicit
profile adapters. The target reusable implementation is under
`ab/{core,runtime,services,repo,stack,system}`. Z Nix composition/integration
remains under `nix/**`, and concrete deployment data remains under `hosts/**`
and `config/**`. Z machine/image/install composition is specifically owned by
thin `nix/profiles/**`, `nix/images.nix`, `nix/installer.nix`, and
`nix/installer-build-image.nix` binders over `ab-system` / `ab-runtime` APIs.
After Phase 14D the generic `lib/` ownership bucket is absent entirely. Reusable
tests live with their `ab/**` owners; repository/deployment integration tests
live under `nix/tests/**` or concrete Z service/profile test directories.

`ab-core` also exposes composition-time seams that must be stable before a bound
`ab` context exists: `core.registryModule` and `core.toolchainOverlays`. The
complete Rust package/mirror/qualification ownership cell lives under
`ab/core/packaging/rust/**`; it uses `core.project` directly and must not depend
on Z's `nix/project.nix`.

Phase 14E also makes generic composition engines explicit APIs:
`core.flake.{apps,devShells}`, `repo.flake.{outputs,self}`,
`repo.{projectionDomains,runtimeCloseouts}`,
`stack.config.{family,prebuiltFamily}`, `stack.fabric.projection`, and
`stack.phase.{projection,ingressProfiles,routeProfiles}`. Z keeps only binders
that inject repository tests, completion hooks, inventory, phase documents and
other deployment-specific context.

Phase 14F applies the same ownership rule to Podman integration: runtime owns
neutral port/readiness/firewall mechanics, Nginx owns reverse-proxy policy and
projection, and stack tunnels own tunnel declaration/projection. Nginx/tunnel
constructors receive the neutral runtime fact projector explicitly, so no
runtime -> service/stack dependency or sibling-source import is introduced.

Generic installer, disk override, persistence, installer-set/image algebra, spec
realization, and the installer CLI live under `ab/system/installer/**`.
`nix/installer.nix` supplies only repository source filtering and concrete
user/profile data; `nix/installer-build-image.nix` binds self-flake evaluation
for the CLI. Reusable installer constructors receive repository/source/user data
explicitly and do not import Z `users/**`, `hosts/**`, or `nix/**` source.

The composition-purity follow-up completes those splits: AI NixOS rendering is
service-owned, host-agent/host-manager NixOS integration is service-owned,
builder-GC coordination is system-owned, Podman-to-host-agent adaptation is
host-agent-owned, and Cloudflare/Rathole host-managed planning is runtime-owned.
Z retains only concrete declarations, secret resolution, inventory/repository
binding, and final assembly.

Phase 14I closes the `lib/` migration: `lib/` is absent, historical moved paths
are physically absent, resolved `ab/**` source paths do not escape into Z roots,
root check owners are pairwise disjoint, and the canonical root surface remains
stable. Historical fake old-path strings may remain only inside explicit
security fixtures; they are not compatibility surfaces.

The stricter post-Phase-14 target is **Nix composition purity**: `nix/**` is not
a reusable implementation bucket. Product-neutral option schemas, NixOS modules,
renderers, lifecycle helpers and scripts belong with their reusable `ab/**`
owner. Z assembly, explicit adapters and integration tests remain under
`nix/**`; `nix/ext/**` is the one reserved exception, owning upstream-following
source recipes/pins/updaters. Concrete package/product source remains under
`pkgs/**` rather than being forced into `ab/**`, and there is no parallel
top-level `sources/**` root.

For Nix source namespaces, never keep both `foo.nix` and `foo/`. If a namespace
has a directory, its entrypoint is `foo/default.nix` and consumers import
`./foo`. This convention is Nix-specific and does not replace language-native
module layouts such as Rust `foo.rs + foo/`.

Z composition must use the curated component APIs rather than importing
`ab/core/packaging/**` or `ab/core/nixos/**` implementation files directly.
Owner-local tests and qualification code may exercise those implementation
files. The bound user-facing registry seam remains `ab.nixos.registryModule`.

## Removed compatibility surfaces

Current source must not reintroduce:

```text
pkgHelper
stack.pkg
stack.srv
ab.service
standalone injected toolchains
*ToolchainFor
craneLibFor
lib/flake/stack/package.nix
lib/services/nginx
```

Historical receipts may mention these names because they describe earlier
checkpoints; current code and normative guidance use only the canonical model.

## Qualification

Boundary changes should retain the permanent extraction gates:

```text
abird-external-core-package
abird-external-runtime
abird-external-services
abird-external-repo
abird-external-stack
abird-component-boundaries
```

Package changes additionally qualify root/child composition identity where
relevant. Runtime/service changes run their owning focused tests. Do not replace
real implementation qualification with ever-growing textual fixtures. Keep
public API and source-ownership guards, but do not freeze private implementation
filenames. Package/stack contract tests exercise ambiguity, collision rejection,
laziness and reconstruction behavior.
