# Language toolchains

Use the native Nixpkgs builder or runtime when it expresses the project's
contract (including a versioned attribute such as `pkgs.nodejs_24`). A helper,
host script or test does not need a resolver just to use the default. The
project owns its dependencies: Cargo uses its lockfile, Node uses the project's
npm/pnpm/Yarn lock, Deno uses its config and lock, and `uv` with `uv.lock` is
the default for Python project management. Go module metadata declares
compatibility; do not let a production build download its compiler.

## When to resolve

Use `ab.toolchains.<language>` when a source-declared version must be enforced,
a pinned provider fills a real Nixpkgs gap, or compiler identity has to agree
across a producer and its consumers. For example, a package requiring an exact
Go version can construct its build with
`(ab.toolchains.go { version = requiredVersion; }).build.mod`. A helper
accepting a selected toolchain must own that build or verify its producer
identity. Do not wrap a local package in a resolver contract just to read it
back out.

All five resolvers accept `null` for the effective package-set default, or a
provider-specific contract. `{ provider = "resolved"; pkg = tool; }` supplies an
already resolved immutable derivation (for Rust, the toolchain bundle). Version
selectors are language-specific, not a common parser for all five languages.

| Resolver | Version selection                                               | `tools` fields                        | `build` fields              |
| -------- | --------------------------------------------------------------- | ------------------------------------- | --------------------------- |
| `go`     | Nixpkgs line or exact version; native `go-overlay` fallback     | `go`                                  | `mod`                       |
| `node`   | Nixpkgs major line or its exact version                         | `node`                                | `npm`                       |
| `python` | Nixpkgs minor line or its exact version                         | `python`                              | `pkgs`, `pkg`, `app`        |
| `deno`   | Current Nixpkgs version                                         | `deno`                                | none                        |
| `rust`   | Nixpkgs/Crane or pinned provider contract, not a bare `version` | `rustc`, `cargo`, `clippy`, `rustfmt` | `pkgs`, `crane`, `validate` |

Go's automatic fallback needs an exact version and the pinned overlay input. It
uses the caller's Nixpkgs: a provider's binary cache need not match. Cross
builds use Nixpkgs' spliced compiler or an explicitly resolved spliced compiler.
Custom Rust selections are native-only; pinned Nixpkgs, Fenix and Oxalica
adapters keep acquisition behind the resolver. Add external providers for real
version gaps, not speculatively.

## Result and ownership

Every result has `pkg` (shell/simple consumer), `tools` (constituents), `build`
(native build integration), `provider`, `id` and `custom`. `id` identifies the
effective tool, not the provider label; for Rust it binds rustc and Cargo. Rust
builds use the matching Crane context and `build.validate` to reject conflicting
compiler overrides. There are no public `*ToolchainFor` or `craneLibFor`
aliases.

The bound `ab.toolchains` reads `pkgs.toolchains` lazily. Composition installs
the ordered language overlays from `core.toolchainOverlays` on one package set;
provider-aware child flakes use the same bundle. Plain standalone composition
can reuse the existing package set without installing overlays. Leaves neither
import `ab/core/packaging/*/toolchain.nix` nor extend `pkgs` for themselves.
Resolver implementations belong to their
[language packaging](language-packaging.md) owner; the composed contract is
exercised in `lib/tests/repository/language-toolchains.nix`.
