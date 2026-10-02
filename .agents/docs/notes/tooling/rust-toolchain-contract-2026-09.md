# Rust toolchain contract across our projects (2026-09)

> **Implementation direction updated:** keep the repository's current toolchain
> as default; prefer fenix for external/custom needs when supported, with
> oxalica available for projects using it or needing its toolchains. Keep all
> providers swappable. Retain child wrappers and route them through the
> canonical builder. See `rust-fabric-foundation-2026-10.md` for the authorized
> checkpoint. The oxalica-first and retire-wrapper recommendations below are
> historical.

Purpose: record what each of **our own** Rust projects uses for its build and
toolchain, and design a **per-capsule toolchain contract** for the fabric so
that (a) imported first-party repos keep their exact toolchains, (b) cross-repo
cache parity becomes a deliberate, checkable choice, and (c) the current parity
hole (child-flake wrappers) is closed.

Companion docs: `.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md`,
`.agents/docs/plans/first-party-external-repo-integration-2026-09.md`,
`.agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md`.

---

## 1. Survey — what our Rust projects use

| project                                           | build mechanism                                                                                           | toolchain source                                              | nixpkgs            | crane                                         |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ------------------ | --------------------------------------------- |
| **Abird monorepo** (24 root members)              | repo `pkgHelper.mkRustDerivation` + `craneLib` from the root overlay                                      | nixpkgs rustc                                                 | `nixos-26.05`      | `github:ipetkov/crane` (lock rev `73b98051…`) |
| **Pvl `nix` monorepo** (5 root members)           | same                                                                                                      | nixpkgs rustc                                                 | `nixos-26.05`      | same lock rev                                 |
| **Child flake wrappers** (20 in Abird, 13 in Pvl) | `lib/flake/stack/package.nix` → `pkgHelper` with `craneLib == null` → **`rustPlatform.buildRustPackage`** | nixpkgs rustc                                                 | **`nixos-25.11`**  | **none**                                      |
| **`dotlink`** (`github.com/abird-ai/dotlink`)     | own crane flake                                                                                           | **oxalica `rust-overlay` + `rust-toolchain.toml` `1.98.1`**   | `nixos-unstable`   | **`v0.24.0`**                                 |
| **`aw`** (first-party workspace, 11 crates)       | own crane flake                                                                                           | nixpkgs rustc (**pinned commit** `a32edd76…`)                 | pinned commit      | pinned rev `eb35abda…`                        |
| **`abird-health`**                                | flake **devShell with `rustup`** (`trunk`, `cargo-tauri`, gtk3/webkitgtk)                                 | **`rust-toolchain.toml` `1.95.0` + `wasm32-unknown-unknown`** | `nixpkgs-unstable` | none                                          |
| `abird-ai`                                        | Node/TS (no Rust)                                                                                         | —                                                             | —                  | —                                             |

So we own **four different Rust toolchain mechanisms**: nixpkgs rustc (monorepo
and `aw`), oxalica rust-overlay + toolchain file (`dotlink`), rustup + toolchain
file (`abird-health`), and the `rustPlatform` fallback with no crane (child
flakes).

## 2. Abird monorepo member survey

- **Editions**: 2021 for most; **2024** for `abird-agent`, `abird-protocol`,
  `abird-host-agent`, `abird-host-manager`, `abird-app/src-tauri`, `abird-web`,
  `gap3-hello`. No `rust-version` in any member; no `rust-toolchain.toml` in the
  monorepo.
- **Build scripts**: only `pkgs/apps/abird-app/src-tauri` (`build.rs`, Tauri).
- **wasm32 / CSR**: `abird-web` and `gap3-hello` are Leptos `csr` +
  `wasm-bindgen`
  - `web-sys` → **target `wasm32-unknown-unknown`**, not the host.
- **Tauri**: `abird-app/src-tauri` (`tauri-build`, `tauri`/`wry`) →
  GTK3/WebKitGTK native inputs (Linux) **and** the wasm build of `abird-web` as
  a compile overlay.
- **Native-ish**: `sqlite-queue` uses `rusqlite { features = ["bundled"] }`
  (compiles the SQLite amalgamation → needs a C compiler, no system sqlite);
  `abird-agent`/`abird-host-agent`/`abird-host-manager` use `libc`.
- **Multi-bin members**: `abird-agent` (2), `search` (1), `nats-wrecking-ball`
  (3), `postgres-queue` (3), `sqlite-queue` (3).
- **Isolated workspaces**: `hello-rust-isolated`, `labs/rust-tictactoe` (edition
  2024), `labs/web3-price-indexer` (virtual workspace).

## 3. The parity hole: child flake wrappers

The child `flake.nix` wrappers (20 Abird / 13 Pvl) are presented as the
standalone/child path, but:

- they pin **`nixpkgs nixos-25.11`** while the monorepo pins **`nixos-26.05`**;
- `lib/flake/stack/package.nix` does not inject `craneLib` (confirmed: no
  `crane` reference), so `craneLib == null` →
  **`rustPlatform.buildRustPackage`**, a different builder from the monorepo's
  crane path.

Consequence: today's "standalone package flake" produces a **different
derivation on a different nixpkgs** than the monorepo build — exactly the
G10/G11 parity failure the fabric was designed to eliminate. Either route the
child flakes through the same fabric/toolchain, or retire them in favour of
generated mirrors.

## 4. Design — per-capsule toolchain contract

The fabric currently assumes **one** toolchain (nixpkgs rustc) and injects a
**single `pkgs.craneLib`**. That cannot host a project that pins its own
toolchain (dotlink) or targets (wasm32). Introduce a toolchain contract as an
explicit unit-identity input.

```nix
# a capsule's toolchain contract
toolchain = {
  provider = "nixpkgs-rustc" | "oxalica" | "fenix" | "pinned-nixpkgs" | "rustup";
  file     = ./rust-toolchain.toml;           # honored by oxalica (and rustup)
  channel  = "1.98.1" | null;                 # explicit pin alternative
  components = [ "rustfmt" "clippy" ];        # where the provider takes them
  targets    = [ "wasm32-unknown-unknown" ];  # extra std targets
};
```

Mechanics:

- `craneLibFor toolchain` replaces the global `pkgs.craneLib` (one toolchain can
  no longer serve the repo). The fabric's Rust adapter takes the toolchain
  contract and builds `craneLib` with the provider's toolchain.
- The toolchain is already part of the unit identity (the design's
  `Unit.toolchain`), so **different toolchains produce different units** — which
  is correct, not a cache miss.
- Providers are swappable behind the contract; `nixpkgs-rustc` is the default so
  the common case stays simple.
- Cache parity rule (unchanged): cross-repo unit dedup/shared cache requires the
  same **crane rev + nixpkgs rev + rustc + source filter + vendor**. Otherwise a
  toolchain change is a deliberate, visible recompile, not an accident.

Native inputs and cross roles continue to compose: a toolchain contract supplies
the compiler and its `targets`; the native policy supplies GTK/WebKit/pkg-config
(Tauri) and `cc` (rusqlite bundled); the cross model supplies the target triple
and linker.

## 5. Provider choice: oxalica `rust-overlay` vs fenix

| axis                         | oxalica `rust-overlay`                             | fenix                                          |
| ---------------------------- | -------------------------------------------------- | ---------------------------------------------- |
| Honor `rust-toolchain.toml`  | **one-liner** `rust-bin.fromRustupToolchainFile`   | express manually via `toolchainOf` / `combine` |
| Integration                  | **overlay** → pairs with `crane.mkLib              | > overrideToolchain`                           |
| Toolchain source             | official prebuilt binaries                         | prebuilt **and** source-built                  |
| Components                   | prebuilt bundles + `extensions`/`targets` override | **fine-grained `combine`**                     |
| `rust-analyzer` / `rust-src` | per toolchain                                      | **first-class** (dev-shell draw)               |
| Extra targets                | `override { targets = [ … ]; }`                    | `combine` with target components               |
| Ecosystem with crane         | **de-facto standard** (dotlink, crane examples)    | works, wired manually                          |

**Recommendation:** default to **oxalica** for hermetic builds — it reads
`rust-toolchain.toml` directly (matching dotlink and abird-health) and
integrates with the overlay-injected `craneLib`. Consider **fenix** only if we
want rich per-toolchain dev shells (`rust-analyzer`/`rust-src`) or
source-built/custom toolchains; if so, it can be used for dev shells only,
leaving the build path on oxalica. Verify fenix's current toolchain-file API
before relying on it.

## 6. Cross/target requirements this confirms

- **wasm32-unknown-unknown** (`abird-web`, `gap3-hello`, `abird-health`) — real,
  not hypothetical; needs `wasm-bindgen`/`trunk`/`binaryen` (adapter) and the
  toolchain's wasm target.
- **aarch64 cross** (`dotlink` via rust-overlay `targets`) — needs a toolchain
  with the target + a cross linker.
- **Tauri native** (`abird-app`) — GTK3/WebKitGTK/pkg-config as native policy,
  plus the frontend overlay.
- **`cc` for bundled C** (`sqlite-queue` `rusqlite`) — native policy, no system
  sqlite.

## 7. Recommendation and open questions

Recommendation:

1. Adopt the **per-capsule toolchain contract** with `nixpkgs-rustc` default and
   **oxalica** as the pinning provider.
2. Replace the global `pkgs.craneLib` with **`craneLibFor toolchain`**.
3. **Pin crane to an explicit rev** repo-wide (today the URL is unpinned).
4. **Unify or retire the child flake wrappers** (they currently build a
   different artifact on an older nixpkgs).
5. Make cross-repo **cache parity** an explicit goal (converge crane + nixpkgs +
   rustc + source filter) or explicitly accept separate caches.

Open questions:

- One toolchain per repo vs per capsule — default to the repo's, allow a
  per-capsule override; where does the registry live?
- Do we adopt `lib.fileset.toSource` for source filtering (aw uses it precisely
  to keep `include_str!` assets)?
- Do we converge every first-party repo onto the repo-wide nixpkgs/rustc, or let
  each pin (and accept separate caches)?
- Retire the 20/13 child flakes, or re-point them at the fabric?
