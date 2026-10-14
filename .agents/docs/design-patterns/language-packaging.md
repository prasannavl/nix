# Language packaging ownership

Language-specific implementations and resources live in `lib/flake/<language>/`.
The directory owns its constructors, language operations, generic tests and any
associated export or qualification tools. `pkg-helper.nix` remains the public
facade, preserving existing package and stack calls.

Shared runtime implementation is repository-agnostic. Named products, stack
inventories and acceptance expectations belong to repository adapters or
explicit identity tests; the generic library never selects or imports them.

| Owner                         | Content                                                                                             |
| ----------------------------- | --------------------------------------------------------------------------------------------------- |
| `lib/flake/pkg-helper.nix`    | Shared app/check operations, passthru, source naming and facade composition                         |
| `lib/flake/rust/`             | Cargo/Crane constructors, planning, toolchains, exports, Trunk resources, mirrors and qualification |
| `lib/flake/go/`               | Go formatter, checks and package operations                                                         |
| `lib/flake/nodejs/`           | Node/web formatter, checks and static-web package operations                                        |
| `lib/flake/python/`           | Python formatter, checks and package operations                                                     |
| `lib/flake/shell/`            | Shell formatter, checks and script package operations                                               |
| `lib/flake/tests/<topology>/` | Repository product and topology integration                                                         |
| `scripts/`                    | Repository maintenance and operational commands                                                     |

## Composition

Each language's `default.nix` is an implementation factory receiving shared
operations explicitly. Language code selects its own defaults and invokes
ordinary Nixpkgs/Cargo/Crane constructors. The facade merges these disjoint
exports; it does not route by project discovery, normalize manifests or select
new production policy. Keep common mechanics in the facade and language-specific
semantics in the owning directory. Package `default.nix` files remain canonical
build definitions, with the same injectable arguments and standalone behavior.

Rust's source-bound adapter receives the composed helper explicitly so it can
preserve the full facade while closing only Rust entrypoints over its source
context. It retains omitted arguments, explicit refusal and lazy dependencies.
The Abird ordinary lock-policy handling remains repository-owned and distinct
from optional closure/base/mirror admission.

Generic checks localize with the language and register through the shared
flake-check aggregator. Their existing exported check names remain stable.
Repository-specific product/host facts remain in the topology identity home and
enter through `repoChecksFn`; generic code never imports that identity content.

## Tools and source boundaries

A script's owner follows what it implements, not its interpreter or extension.
Rust mirror generation belongs to `rust/mirror/`; its trusted Nix validator
stays adjacent. Reusable Rust qualification support belongs to
`rust/qualification/` and stays optional. Product/repository scenarios belong to
`scripts/qualification/rust/` under explicitly named owners. They inject
`recipeFile`, preserved source paths and seed handles into the generic
framework; shared library code never imports those scenarios. Repository-wide
formatting, update and operational scripts stay under `scripts/`. Do not move
product source under the packaging library.

The mirror source contract excludes the nested tests, mirror CLI and optional
qualification areas from runtime support, just as it previously excluded tests
and kept tooling outside that support tree. Explicit VM support inventories must
include the facade's language factories and Rust dependencies. Moving a resource
must preserve its contents, executable mode and effective source root.

## Validation and history

For moves or extraction, compare public helper names and real package/check
identities before and after. Run language contract checks and tool integration
checks, including root discovery and source exclusions. Update active consumers
and guidance, without rewriting historical receipts or immutable source pins.
Historical replay uses the tooling and layout corresponding to its pinned
source.

There are no flat-path compatibility wrappers: current internal consumers use
canonical language paths, while public constructor names remain stable. Add a
new language directory when it owns real implementation, rather than creating an
empty scaffold or a second registry.
