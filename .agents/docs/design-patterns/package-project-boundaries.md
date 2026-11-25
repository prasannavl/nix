# Package project boundaries

## One graph for root and child builds

| File                  | Owns                                                                                   |
| --------------------- | -------------------------------------------------------------------------------------- |
| Package `default.nix` | Injectable constructor, source/lock inputs, dependencies, metadata and passthru        |
| Child `flake.nix`     | Literal flake/input declarations; delegate output construction to `lib/project.nix`    |
| `pkgs/manifest.nix`   | Root publication: names, aliases, apps and tooling selectors; not dependency injection |

A portable constructor consumes `pkgs` and, when needed, the core-only `ab`. Use
`ab.build`, `ab.package`, `ab.tasks` and `ab.flake` for the
[shared packaging operations](language-packaging.md). Do not import Nixpkgs,
install overlays, construct a fresh `ab`, or discover sibling packages in a
repository registry.

Declare each sibling default in the constructor and resolve it through the
caller's scope:

```nix
{pkgs, ab, dependencyA ? ../dependency-a}:
ab.package.withDeps {inherit dependencyA;} ({dependencyA}: ...)
```

`withDeps` calls only Nix paths; an already built dependency, a supported `null`
override or any other non-path passes through unchanged. It does not interpret
`{ path = ...; args = ...; }` as a constructor. Root and child composition use
the same recursive scope, not copies of the graph. A child flake retains literal
loader metadata rather than importing its entire input set from a helper.

## Deployment and validation

Never pass a real or stub deployment `stack` into a portable build. Bind service
policy in a NixOS module or repository adapter around the **already built**
package. Isolated builds do not require host topology or deployment secrets.
Preserve shared source and lock inputs where the repository supplies them.

Compare root and child package identities, passthru (including
`flakeExtraNixosModules` where exported), output names, checks and apps when
changing composition. A successful build alone will not detect a dropped module
export. See
[context and component boundaries](abird-context-and-component-boundaries.md)
for scope and publication rules, and [Rust patterns](../lang-patterns/rust.md)
for Rust packages.
