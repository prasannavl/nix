# Package Flake Composition

Packages under `pkgs/` define a build once, in `default.nix`. Root publication
and standalone child flakes call that constructor with the same `pkgs` and `ab`
package-author context. Use [`pkgs/manifest.nix`](../pkgs/manifest.nix) for root
publication metadata, not to repeat package dependencies.

## Package constructors

Use a bound `ab.build` builder for the language: `rust`, `trunk`, `go`,
`python`, `web`, `staticWeb`, `shell`, or `aggregate`. Do not import Nixpkgs, an
overlay, or a package-helper file from the leaf.

For example, [`hello-rust`](../pkgs/examples/hello-rust/default.nix) uses its
repo-root Cargo workspace and exports a NixOS service module:

```nix
{pkgs, ab}:
ab.build.rust {
  inherit pkgs;
  pname = "hello-rust";
  version = "0.1.0";
  projectDir = "pkgs/examples/hello-rust";
  extraPassthru.nixosModule = ab.nixos.service {};
}
```

`projectDir` selects the workspace member. The root `Cargo.toml` and
`Cargo.lock` govern the workspace build; `deps` names other member directories
needed in the source. Passing a built sibling via `internalDeps` also supplies
its `passthru.projectDir`. When workspace artifact layering is enabled, build
artifacts can be reused without adding them to the runtime closure. See the
[Rust packaging guide](../ab/core/packaging/rust/README.md) for that policy. For
an existing native derivation, see
[`hello-go`](../pkgs/examples/hello-go/default.nix): it wraps
`pkgs.buildGoModule` with `ab.build.go`, then uses `ab.package.wire` to attach
its module. Neither constructor needs deployment `stack`.

Declare sibling dependencies once, as constructor arguments. For example,
[`nixbot`](../pkgs/tools/nixbot/default.nix) declares
`buildController ? ../abird-host-manager` and passes `inherit buildController;`
to `ab.package.withDeps`. Its callback adds the resolved build controller to the
shell application's `runtimeInputs`.

`withDeps` resolves a Nix path in the same package scope. An explicitly supplied
derivation or other non-path value passes through unchanged. Do not look up a
repository sibling through `pkgs` or restate this dependency in the child flake.

## Child flakes

[`lib/project.nix`](../lib/project.nix) binds the portable `ab.core.project`
engine to this repository's root and `treefmt.toml`. The child `flake.nix` keeps
its literal input declarations and delegates its outputs to that binder. For
[`pkgs/examples/hello-rust/flake.nix`](../pkgs/examples/hello-rust/flake.nix):

```nix
outputs = declaredInputs: let
  inputs = declaredInputs // {rustWorkspaceDeps = false;};
in
  (import ../../../lib/project.nix).mkFlakeOutputs ./. inputs;
```

The relative import is from the child flake's directory. The binder calls the
package constructor and exports its apps, checks, optional dev shell and
package-owned `passthru.nixosModule`; the wrapper does not define the module a
second time. For a native service example, see [Native Services](services.md).

## Outputs and commands

Standard package outputs include `build`, `default`, `run`, `dev`, `fmt` and
`lint-fix`. Apps expose the runnable operations; checks such as `build`, `fmt`,
`lint` and `test` are read-only. Use an app, not a check, to mutate source.

From the repository root:

- `nix build .#example-hello-rust`
- `nix fmt`
- `nix run .#fmt -- --project <name>`
- `nix run .#lint -- --project <name>`
- `nix run .#lint -- fix`

For the [Go example](../pkgs/examples/hello-go/flake.nix):

- `nix build ./pkgs/examples/hello-go`
- `nix run ./pkgs/examples/hello-go#run`
- `nix run ./pkgs/examples/hello-go#fmt`
- `nix build ./pkgs/examples/hello-go#checks.x86_64-linux.test`
- `nix flake check ./pkgs/examples/hello-go`

Root tooling owns repository-wide formatting and lint policy. Child builds
supply language-specific checks and apps: Rust uses Rustfmt, Clippy and Cargo;
Go uses gofmt, go vet and go test; Python uses Ruff; web projects use Biome. For
specialized tasks see the public `ab.tasks`, `ab.package` and `ab.flake`
operations in [`ab/core/default.nix`](../ab/core/default.nix).
