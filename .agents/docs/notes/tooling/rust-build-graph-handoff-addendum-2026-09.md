# Rust build-graph handoff — ADDENDUM (learnings since the base handoff)

Read after `.agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md`.
This addendum covers everything learned **after** that handoff: the Abird
applicability mapping, the Bazel/Buck2 comparison (and the remote-build
correction), the first-party external-repo integration design, and the Rust
toolchain contract. It also updates the reading order, decisions and pending
items. Nothing here changes the base handoff's "verified facts" or "decided"
items except where explicitly noted.

---

## 1. The design set is now mirrored in BOTH repos

Pvl (`/home/pvl/src/nix`) and Abird (`/home/pvl/spaces/abird/src/z`) carry
byte-identical copies of:

- **Plans:** `rust-build-graph-final`, `rust-workspace-build-graph`,
  `design-l-implementation`, `design-f-build-graph` (superseded),
  `dual-mode-rust-build-graph` (Design M), `g4-base-locality` (Design G4),
  `multi-ecosystem-build-fabric`, `first-party-external-repo-integration`.
- **Notes/tooling:**
  `rust-build-graph-{handoff,decision,review,dual-mode-goals,
  g4-locality,abird-applicability}`,
  `rust-toolchain-contract`, `build-system-comparison-bazel-buck2`,
  `cargo-workspace`, and the `rust-build-graph-councils/` archive (21 files:
  research, candidate plans, critiques, finals for the three councils).

Both `.agents/docs/README.md` files index these. **Nothing is committed** in
either repo; the docs are untracked (Abird's `plans/` dir is entirely new
there).

---

## 2. Abird applicability (`.agents/docs/notes/tooling/rust-build-graph-abird-applicability-2026-09.md`)

- Abird is the **24-member target**: 804 packages, 44
  `[workspace.dependencies]`, 223 `workspace = true` (192 in root members), 7
  root-member path edges, 3 isolated workspaces (`hello-rust-isolated`,
  `labs/rust-tictactoe`, `labs/web3-price-indexer`), and a real Deno project
  (`pkgs/ext/gcp-cloud-run/xtest`).
- **Design L is NOT landed in Abird** (`lib/flake/pkg-helper.nix` has 0 DAG
  symbols) → the parity port is the prerequisite for any design here.
- Mapping recorded: G4 per-member closures + closure-subset chaining edges
  (`protocol ⊆ agent/web/app-tauri/host-manager`; `host-agent ⊆ host-manager`;
  `parrot-core ⊆ tg-parrot/zulip-parrot`; `robin-core ⊆ zulip-robin`, ~24 base
  nodes); Design M path-connected components; and the fabric's Tauri/wasm/Deno
  adapters.
- Abird needs the **cross-ecosystem overlay mechanism** (`compileOverlays`) for
  `abird-app/src-tauri` ← `abird-web`; Design L/M/G4 are Rust-only.
- Nested member dir `pkgs/apps/abird-app/src-tauri` and the isolated workspaces
  must be handled by the source filter / closure computation.

---

## 3. Build-system comparison vs Bazel and Buck2 (`.agents/docs/notes/tooling/build-system-comparison-bazel-buck2-2026-09.md`)

- **Convergence:** Bazel/Buck2 do **not** natively resolve package-manager
  graphs; they rely on generators (`rules_rust` `crate_universe`, Gazelle,
  `rules_python` lock importers, Meta's **reindeer**) that ingest the
  ecosystem's lock. That is the same "capture the resolver" idea as our
  committed **ledger** — we make it a core mechanism; they pay per-ecosystem
  rule maintenance.
- **They are stronger at:** action-level remote execution (REAPI +
  byte-streaming), a warm analysis daemon (Skyframe / Buck2 daemon), query
  tooling (`query`/`cquery`/`aquery`, `bxl`, BEP/BES), platforms/constraints +
  configuration transitions, and proven massive scale.
- **We are stronger at:** native resolvers as the single source of truth (no
  BUILD/BUCK for third-party deps), no-IFD with exact resolution via the ledger,
  first-class mirrors + adoption (G10/G11), Nix-native packaging/deployment, and
  fail-closed per-capsule modes.
- **Remote-build correction (important):** Nix remote builds are **already
  incremental at derivation granularity** — the client evaluates the graph, and
  only derivations absent from the client store / remote builder store / a
  substituter are built and distributed (unchanged ⇒ zero builds). In this repo
  nixbot builds on `--build-host` (`pvl-x2`, from `config.builders`) which keeps
  a persistent store and serves a signed **Harmonia** cache. So the gap vs
  Bazel/Buck2 is **action-level scheduling/REAPI + a warm analysis daemon**, not
  the absence of remote incrementality. **Evaluation is not offloaded** (client
  eval cost grows with a unit-DAG).
- **Borrow backlog:** a `fabric query`/`aquery` surface, a BEP-like event
  stream, first-class platform/toolchain identity, critical-path reporting, an
  optional REAPI executor behind the unit→derivation seam, and a persisted
  analysis cache.

---

## 4. First-party external repos (`.agents/docs/plans/first-party-external-repo-integration-2026-09.md`)

Three projects we own but that live in **other git repos** (inspected on
`pvl-a1`):

- **`dotlink`** — single Rust crate (edition 2024), own crane flake, GitHub
  remote.
- **`aw`** — Rust **workspace** (`aw-cli` + 11 `crates/aw-*` + many
  `examples/sdk-*`), own crane flake; remote is a local **bundle**.
- **`abird-ai`** — Node/TS Next.js+Vite+Wrangler app (npm lock), no flake;
  remote is a local **bundle**. All three are mutually independent.

Four integration models:

1. **Opaque flake input** (rev-pinned, `follows = "nixpkgs"`) — trivial, but no
   unit-level sharing, and a single crate is only takeable if exported.
2. **In-tree import** (subtree/submodule/vendor) — full sharing, but churn; Nix
   flakes don't fetch submodules by default, so subtree/vendor is safer.
3. **Provider + committed ledger** (fabric-native) — keep the repo external,
   publish a provider descriptor + ledger subset; eval reads the committed
   ledger (no IFD); exact units; mirrors/adoption apply.
4. **Fabric Node build** for `abird-ai` — build via the Node adapter from a
   pinned source; consume its export (as a package or a compile overlay).

**Taking a single crate:** in-tree = path dep; external = a Cargo **git dep**
(`crate = { git = "…", rev = "…" }`) which pulls the crate **plus its intra-repo
path deps**, and **requires the ledger** for no-IFD; opaque flake = only if the
external flake exports per-crate packages.

**Model 2 in detail** (doc §9): always Nix-side changes (our build policy,
exclude artifacts); if kept its own workspace, `dotlink` needs a `[workspace]`
opt-out (aw already has one) and a path dep still unifies versions; if absorbed,
remove `[profile.*]` (workspace-root only), `[workspace.dependencies]` pins,
`resolver`, `default-members`, and expect `.cargo/config.toml` to be ignored and
feature unification to widen. **Warning:** absorbing changes their resolution,
which conflicts with G10/G11 "standalone == merged"; binaries can keep their own
capsule, libraries cannot (Cargo can't link a foreign rlib).

---

## 5. Rust toolchain contract (`.agents/docs/notes/tooling/rust-toolchain-contract-2026-09.md`)

We own **four** Rust toolchain mechanisms:

| project(s)                     | mechanism                                                | toolchain                                               | nixpkgs            | crane                                |
| ------------------------------ | -------------------------------------------------------- | ------------------------------------------------------- | ------------------ | ------------------------------------ |
| monorepo (Abird 24 / Pvl 5)    | `pkgHelper` + overlay `craneLib`                         | nixpkgs rustc                                           | `nixos-26.05`      | `github:ipetkov/crane` @ `73b98051…` |
| child flake wrappers (20 / 13) | `stack/package.nix`, `craneLib == null` → `rustPlatform` | nixpkgs rustc                                           | **`nixos-25.11`**  | none                                 |
| `dotlink`                      | own crane flake                                          | **oxalica rust-overlay + `rust-toolchain.toml` 1.98.1** | `nixos-unstable`   | `v0.24.0`                            |
| `aw`                           | own crane flake                                          | pinned nixpkgs commit                                   | pinned             | pinned rev                           |
| `abird-health`                 | flake devShell + `rustup`                                | **`rust-toolchain.toml` 1.95.0 + wasm32**               | `nixpkgs-unstable` | none                                 |

- **Parity hole:** the child flake wrappers build a **different derivation on
  `nixos-25.11` via `rustPlatform`** (no crane) than the monorepo — either unify
  them with the fabric/toolchain or retire them in favour of generated mirrors.
- **Design:** a **per-capsule toolchain contract**
  (`provider ∈
  {nixpkgs-rustc, oxalica, fenix, pinned-nixpkgs, rustup}`,
  optional `rust-toolchain.toml`, `targets`, `components`) and
  **`craneLibFor toolchain`** replacing the single global `pkgs.craneLib`. The
  toolchain is already a unit identity input, so different toolchains =
  different units (correct).
- **Provider choice:** default **oxalica** (`fromRustupToolchainFile` reads the
  project's toolchain file directly, matches dotlink, integrates with the
  overlay-injected `craneLib`); use **fenix** only for rich dev shells
  (`rust-analyzer`/`rust-src`) or source-built/custom toolchains.
- **Targets confirmed real:** wasm32-unknown-unknown (Leptos CSR in
  `abird-web`/`gap3-hello`/`abird-health`), aarch64 cross (`dotlink`), Tauri
  native (GTK3/WebKitGTK), and `cc` for `rusqlite { bundled }` (`sqlite-queue`).
- **Parity rule:** cross-repo shared cache needs the same **crane rev + nixpkgs
  rev + rustc + source filter + vendor**.

---

## 6. Updated decisions (this phase)

- Abird confirmed as the 24-member target; every design applies, with the
  Design-L port as the prerequisite.
- Adopt a **per-capsule toolchain contract** with `nixpkgs-rustc` default and
  **oxalica** as the pinning provider; replace `pkgs.craneLib` with
  **`craneLibFor toolchain`**; **pin crane to a rev**; **unify or retire the
  child flakes**.
- The **unit-DAG / Capsule-Ledger** design remains the strongest end state but
  is **not adopted**; its go/no-go spike (producer fidelity) is still pending.
- Design **G4 (closure bases)** + Design **M (mirrors)** remain the Rust
  end-state candidates if the unit-DAG spike fails.
- First-party external repos: prefer **Model 3 (provider + ledger)** for
  libraries, Model 1 for binaries, Model 4 for Node; avoid in-tree absorption
  unless first-class membership is wanted.

## 7. Updated pending items

Carried over: unit-DAG go/no-go spike; unit-DAG vs G4 decision; 24-member cost
measurement; G4 `.rs` add/remove wart; G4 implementation; Abird port;
`lib/flake` extraction; child-flake migration; commit the docs; push `master`;
reconcile the 753-vs-712 closure sums.

New: toolchain-contract decision (oxalica vs fenix; `craneLibFor`); pin crane to
a rev; fix the child-flake parity hole; define the external-repo **provider
descriptor schema**; push `aw`/`abird-ai` off their local bundles to real
remotes; decide cross-repo **cache parity** vs separate caches; consider
`lib.fileset.toSource` for source filtering.

## 8. Updated reading order

Base handoff items 1–14, **plus** (in this order):

15. `build-system-comparison-bazel-buck2-2026-09.md`
16. `first-party-external-repo-integration-2026-09.md`
17. `rust-toolchain-contract-2026-09.md`
18. `rust-build-graph-abird-applicability-2026-09.md`
19. `rust-build-graph-councils/` (raw council artifacts)

## 9. Starting prompt (addendum)

```text
Continue the repo-wide Rust / multi-ecosystem build-graph design effort in
/home/pvl/src/nix (mirrored in /home/pvl/spaces/abird/src/z).

Read, in order:
  1. .agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md
  2. .agents/docs/notes/tooling/rust-build-graph-handoff-addendum-2026-09.md  (this)
  3. the "updated reading order" in section 8

Do not re-litigate the base handoff's "verified facts"/"decided" items. Design
only — do not change code unless asked.

Then tell me: (1) the current state, (2) the open decisions, and (3) your
recommended next step. The immediate decision is the unit-DAG/Capsule-Ledger
producer-fidelity spike vs proceeding with Design G4 + Design M, and the new
adjacent decision is the per-capsule toolchain contract (oxalica vs fenix,
craneLibFor) and fixing the child-flake parity hole. Ask before anything
expensive.
```
