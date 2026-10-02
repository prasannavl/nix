# Abird applicability — Rust build-graph designs (2026-09)

Purpose: confirm that the design set (Design L, Design M, Design G4, the
multi-ecosystem fabric, and the unit-DAG Capsule/Ledger design) applies to the
**Abird** repository (the `abird` git remote), and record the concrete mapping.
Companion to `.agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md`.

Repo: `/home/pvl/spaces/abird/src/z`, branch `master`, HEAD `af41317a`, clean
(`## master...origin/master`).

---

## 0. Headline

The designs are **workspace-agnostic and apply to Abird**, with three
Abird-specific facts to hold in view:

1. **Design L is not landed in Abird.** `lib/flake/pkg-helper.nix` contains none
   of the DAG symbols (`mkSharedRustDepsBase`, `memberLayer`,
   `rustWorkspaceMembers`). The parity port (Pvl → Abird) is the prerequisite
   for any of these designs; see the port process referenced below.
2. **Abird is the 24-member target**, so the cost measurements that were
   mandatory gates (the G4 24-member measurement, the fabric's per-ecosystem
   scale gate) are _Abird's actual numbers_, not projections.
3. **Abird needs the cross-ecosystem overlay mechanism** (the fabric's
   `compileOverlays`) for its Tauri app: Design L/M/G4 are Rust-only and cannot
   express "build `abird-web` and inject its output into `abird-app`". The
   fabric is the design that covers Abird's real app composition.

---

## 1. Verified Abird workspace shape

- **24 root members** (`Cargo.toml` `[workspace] members`):
  `pkgs/bots/{parrot-core,
  robin-core, tg-parrot, zulip-parrot, zulip-robin}`,
  `pkgs/examples/{edi-ast-parser-rs,
  hello-rust}`,
  `pkgs/srv/{abird-agent, ingest, llm, search, trading-api,
  trading-processor, trading-transformer-excel}`,
  `pkgs/support/{abird-protocol,
  nats-http-bridge}`,
  `pkgs/tools/{abird-host-agent, abird-host-manager,
  nats-wrecking-ball, postgres-queue, sqlite-queue}`,
  `pkgs/apps/abird-app/src-tauri`, `pkgs/web/{abird-web, gap3-hello}`.
- `Cargo.lock` v4, **804 packages** (24 local, 780 registry, 0 git).
- **44** `[workspace.dependencies]` entries; **223** `workspace = true`
  declarations across all `pkgs/**` (192 inside the 24 root members).
- **7 root-member path edges:** `abird-app/src-tauri → abird-protocol`,
  `abird-web → abird-protocol`, `abird-agent → abird-protocol`,
  `abird-host-manager → abird-host-agent`, `tg-parrot → parrot-core`,
  `zulip-parrot → parrot-core`, `zulip-robin → robin-core`.
- **3 isolated workspaces** (own `[workspace]`/lock, not root members):
  `pkgs/examples/hello-rust-isolated`, `pkgs/labs/rust-tictactoe`,
  `pkgs/labs/web3-price-indexer` (the last also has an internal path edge
  `crates/indexer → crates/indexer-data`).
- **Non-Rust projects:** Deno (`pkgs/ext/gcp-cloud-run/xtest/deno.json`), plus
  Node/Python/Go **examples** (`hello-node`, `hello-python`, `hello-go`); no
  C++/CMake/Meson projects yet.

---

## 2. Mapping each design onto Abird

### Design L (single shared `--workspace` base + per-member layers)

- Directly applicable: one base over the 24-member union, one artifacts-only
  layer per member, `internalDeps` for the 7 path edges.
- `rustWorkspaceMembers` glob guard is fine (Abird's member list is explicit, no
  globs).
- Residual recompiles scale with the 24-member union; the same feature-union
  residual applies.
- **Prerequisite:** port the L mechanics to Abird (`pkg-helper.nix`, wiring,
  `Cargo.toml` normalization) via the parity process.

### Design M (MIRROR-L: `base` seam, layout-preserving mirrors, adoption)

- **Mirror unit = path-connected component.** In the root workspace that is:
  - `{abird-app/src-tauri, abird-web, abird-agent, abird-host-manager,
    abird-host-agent, abird-protocol}`
    (all connected through `abird-protocol` and `abird-host-agent`);
  - `{tg-parrot, zulip-parrot, parrot-core}`;
  - `{zulip-robin, robin-core}`;
  - the remaining ~15 members as singletons;
  - plus the 3 isolated workspaces as separate mirror units.
- `externalPackagesFor` adoption applies per package; layout-preserving mirrors
  give identical drv paths.
- `lib/flake` extraction tiers apply; note the mirror's Tauri/Leptos specifics
  (see §3).

### Design G4 (CLOSURE-BASES: per-member closure bases, shared vendor)

- `closure(m) = {m} ∪ transitive in-repo path deps`. Examples:
  - `closure(abird-protocol) = {abird-protocol}`
  - `closure(abird-agent) = {abird-agent, abird-protocol}`
  - `closure(abird-web) = {abird-web, abird-protocol}`
  - `closure(abird-app/src-tauri) = {abird-app/src-tauri, abird-protocol}`
  - `closure(abird-host-manager) = {abird-host-manager, abird-host-agent,
    abird-protocol}`
  - `closure(tg-parrot) = {tg-parrot, parrot-core}`,
    `closure(zulip-parrot) = {zulip-parrot, parrot-core}`
  - `closure(zulip-robin) = {zulip-robin, robin-core}`
  - the remaining ~15 members are singletons.
- **Closure-subset chaining edges** (the only legal `cargoArtifacts` parents):
  `protocol ⊆ agent/web/app-tauri/host-manager`; `host-agent ⊆ host-manager`;
  `parrot-core ⊆ tg-parrot/zulip-parrot`; `robin-core ⊆ zulip-robin`.
- **Base node count = 24** (one per member), vs 5 in Pvl; each with the **one
  shared full-lock vendor**. The **24-member cost measurement is Abird's real
  gate** before `member` becomes the default.
- The `.rs` add/remove wart and the manifest-only-base lever apply unchanged.
- Nested member dir `pkgs/apps/abird-app/src-tauri` must be handled by the
  source filter / members rewrite (it is a member whose `projectDir` is nested).

### Multi-ecosystem fabric

- Applies directly; Abird is the target scale.
- **Real Abird adapters needed:** Tauri (`abird-app/src-tauri` + a
  `compileOverlays.frontend-dist = abird-web` compile overlay), WASM/Trunk or
  Leptos (`abird-web`, `labs/*`), Deno (`ext/gcp-cloud-run/xtest`), plus the
  Node/Python/Go examples as demonstrations. No C++ project yet (the C++ adapter
  stays tier B/C when one appears).
- **Isolated workspaces** (`hello-rust-isolated`, `labs/rust-tictactoe`,
  `labs/web3-price-indexer`) are ordinary capsules/plan roots with their own
  contract+lock; identical registry units can converge with the main workspace.
- **Fetched external Rust roots** (Stalwart, `tuicr`) are ordinary plan roots;
  no special category.

### Unit-DAG "Capsule · Ledger · Modes" design

- The design's own verified current-state section is Abird (24 members, 804
  packages, 44 workspace deps, 192 workspace=true, 7 path edges) — it was
  written against Abird. It applies as-is; the go/no-go spike (producer
  fidelity) should be run on Abird's real lock.

---

## 3. Abird-specific design considerations

1. **Cross-ecosystem overlays are required, not optional.** `abird-app` is a
   Tauri crate (`pkgs/apps/abird-app/src-tauri`) that consumes a frontend built
   from `abird-web`; Design L/M/G4 (Rust-only) cannot express this. The fabric's
   `compileOverlays` (edge kind 2) is the mechanism.
2. **`abird-web` / `gap3-hello` / `labs` are Rust (wasm-capable) crates**, so
   WASM/host-target role separation and the wasm linker/`wasm-bindgen`/binaryen
   adapter apply.
3. **Nested member dirs** (`pkgs/apps/abird-app/src-tauri`) and **isolated
   workspaces** must be handled by both the source filter and any
   component/closure computation.
4. **Toolchain/pins differ from Pvl** (nixpkgs `6d663c05…` nixos-26.05, crane
   `73b9805…`, rustc/cargo 1.95.0). Cache parity between repos requires the same
   pins; the fabric's "one canonical library flake, consumers agree on pins when
   cache parity is wanted" covers this.
5. **Two-repo parity.** The shared `lib/**` and `pkgs/**` should stay
   byte-identical across Pvl and Abird per
   `.agents/docs/notes/tooling/shared-tooling-parity-2026-07.md`; the Abird port
   process is documented on the Pvl side
   (`.agents/docs/notes/tooling/abird-post-3fc-port-2026-08.md`).
6. **Line-number caveat:** the design docs reference `lib/flake/pkg-helper.nix`
   symbols by name, with Pvl line numbers; Abird's file differs (pre-DAG) until
   the port lands.

---

## 4. Checklist when porting / adopting in Abird

- [ ] Port Design L (or the chosen final design) to Abird via the parity
      process; keep shared `lib/**`/`pkgs/**` byte-identical where the contract
      requires.
- [ ] Re-run the ecosystem inventory on Abird and confirm the Deno/Tauri/WASM
      adapters needed.
- [ ] Re-run the closure/component computation and the **24-member cost
      measurement** (the G4 gate) on Abird's real manifests.
- [ ] Add `compileOverlays` for `abird-app` ← `abird-web` and verify the Tauri
      build.
- [ ] Land or defer the unit-DAG spike on Abird's real lock.
- [ ] Generate per-package/component mirrors from the evaluated rev; wire
      `externalPackagesFor`; run `mirror-fresh` / `mirror-parity` /
      `mirror-standalone`.
- [ ] Keep `Cargo.lock` and the toolchain pins aligned with Pvl when cache
      parity is wanted.

---

## 5. Rust toolchain landscape across Abird and its sibling repos

Full detail and the design:
`.agents/docs/notes/tooling/rust-toolchain-contract-2026-09.md`.

| project                         | build                                                     | toolchain source                                        | nixpkgs            | crane                                |
| ------------------------------- | --------------------------------------------------------- | ------------------------------------------------------- | ------------------ | ------------------------------------ |
| Abird monorepo (24 members)     | repo `pkgHelper` + overlay `craneLib`                     | nixpkgs rustc                                           | `nixos-26.05`      | `github:ipetkov/crane` @ `73b98051…` |
| child `flake.nix` wrappers (20) | `stack/package.nix`, `craneLib == null` -> `rustPlatform` | nixpkgs rustc                                           | **`nixos-25.11`**  | **none**                             |
| `dotlink`                       | own crane flake                                           | **oxalica rust-overlay + `rust-toolchain.toml` 1.98.1** | `nixos-unstable`   | `v0.24.0`                            |
| `aw`                            | own crane flake                                           | pinned nixpkgs commit `a32edd76…`                       | pinned             | pinned rev `eb35abda…`               |
| `abird-health`                  | flake **devShell + rustup**                               | **`rust-toolchain.toml` 1.95.0 + wasm32**               | `nixpkgs-unstable` | none                                 |

Abird member survey: editions mixed 2021/2024 (2024 for `abird-agent`,
`abird-protocol`, `abird-host-agent`, `abird-host-manager`,
`abird-app/src-tauri`, `abird-web`, `gap3-hello`); only `abird-app/src-tauri`
has `build.rs` (Tauri); `abird-web`/`gap3-hello` are Leptos CSR + wasm32;
`sqlite-queue` uses `rusqlite { bundled }` (needs `cc`); `libc` in the agent
crates; multi-bin members `abird-agent`, `search`, `nats-wrecking-ball`,
`postgres-queue`, `sqlite-queue`; isolated workspaces `hello-rust-isolated`,
`labs/rust-tictactoe`, `labs/web3-price-indexer`.

**Parity hole:** the child flake wrappers build a **different derivation on
`nixos-25.11` via `rustPlatform`** (no crane) than the monorepo build. Unify
them with the fabric/toolchain or retire them in favour of generated mirrors.
