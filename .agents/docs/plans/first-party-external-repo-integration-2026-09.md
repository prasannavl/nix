# Integrating first-party external repos (dotlink · aw · abird-ai) — design

Status: design only. How to bring projects we own but that live in **other git
repos** into the nix monorepo's build/cache architecture, without importing the
source unless we choose to.

Companion docs: `.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md`
(the fabric), `.agents/docs/design-patterns/rust-foundation.md`,
`.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`.

---

## 0. The three projects (verified on `pvl-a1`)

| project                       | kind    | shape                                                                                                                                                 | own flake                   | git remote                                   | notes                                                                                                                |
| ----------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `~/spaces/abird/src/dotlink`  | Rust    | **single crate** `dotlink` v0.6.0, edition 2024                                                                                                       | yes (crane, nixos-unstable) | `github.com/abird-ai/dotlink`                | one binary; no internal path deps                                                                                    |
| `~/spaces/abird/src/aw`       | Rust    | **workspace**: `aw-cli` + `crates/aw-{identity,inference,client,surfaces,agent-core,providers,tools,store,workspace,git,terminal}` + `examples/sdk-*` | yes (crane)                 | local **bundle** (`aw-phase-14-…bundle`)     | resolver 2, exact `=x.y.z` pins, large optional-feature matrix; crates depend on each other via intra-repo path deps |
| `~/spaces/abird/src/abird-ai` | Node/TS | Next.js 16 + Vite + Wrangler (Cloudflare), npm lock, drizzle                                                                                          | no                          | local **bundle** (`abird-ai-b48654a.bundle`) | web app; not a flake                                                                                                 |

All three are **mutually independent** (no cross-references to each other or to
the nix repo's `abird-*` crates). Practical note: `aw` and `abird-ai`'s origins
are **local bundle files**, which are not valid flake input URLs; adopting them
as flake inputs requires pushing to GitHub (the `abird-ai` org) or referencing a
reachable `git+ssh://`/`git+https://` URL.

---

## 1. The constraints that decide the answer

1. **One Cargo workspace per repo.** Cargo resolves within one workspace root
   and one lock. The nix repo cannot "contain" another repo's crates unless
   their **source is materialized inside our tree** (or referenced as a Cargo
   git dep).
2. **No IFD.** Evaluation may not read a derivation. A Cargo **git dependency**
   (or any fetched source) is a derivation, so our pure-eval planner cannot read
   its manifests — unless the source is an **eval-visible path** (committed, or
   a `path:` flake input) or we read a **committed ledger** instead.
3. **The fabric already has the seams** for this: a **provider contract**
   (`providers.nix`), `externalPackagesFor` adoption (G11), mirrors (G10), and
   the committed **ledger/shards**. So "external repo" is a first-class concept,
   not a special case.

Therefore there are four integration models, and the choice is mostly about
**how much unit-level sharing** you want vs **how much you want to keep the
external repo independent**.

---

## 2. Model 1 — opaque flake input ("use as-is")

The external repo's own flake is consumed as a pinned input; its outputs are
used verbatim.

```nix
# repo flake.nix
inputs.dotlink = {
  url = "github:abird-ai/dotlink/93cbd4d…";   # or a tag/rev
  inputs.nixpkgs.follows = "nixpkgs";          # avoid a second nixpkgs
};
inputs.aw = {
  url = "github:abird-ai/aw/<rev>";
  inputs.nixpkgs.follows = "nixpkgs";
};

outputs = { self, nixpkgs, dotlink, aw, ... }: {
  # consume
  packages.${system}.dotlink = dotlink.packages.${system}.default;
  packages.${system}.aw = aw.packages.${system}.default;
};
```

- **What it looks like:** add inputs with a rev; use `packages.<system>.<name>`;
  `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"`.
- **Good:** trivial, no source in our tree, the external repo keeps its own
  release cadence and flake.
- **Bad:** the external derivation is **opaque** — its own crane base, its own
  pins; **no unit-level sharing/dedup** with our graph; cache parity only if
  nixpkgs/crane/toolchain are aligned; you **cannot take a single crate** unless
  the external flake exports it.
- **Non-flake repo (`abird-ai`):** add a thin `flake.nix` there (crane/node
  adapter), or wrap it here (Model 4).
- **Requirements:** a fetchable URL (push `aw`/`abird-ai` off the bundle), and a
  `flake.lock` bump discipline.

## 3. Model 2 — in-tree import (submodule / subtree / vendor)

Materialize the external repo's source inside the nix repo so it participates in
our workspace and graph.

- **Mechanisms:**
  - `git subtree` (files committed in our repo) — **eval-visible**, robust, no
    flake flags needed; carries history.
  - `git submodule` — pinned, but **Nix flakes do not fetch submodules by
    default**; you must either use a `path:` input with submodules enabled or
    commit the contents (subtree/vendor). This is a recurring footgun.
  - vendor (plain copy) — simplest, no history, churn risk.
- **Then:** add the wanted crates to the root `Cargo.toml` `members` (or use
  path deps) and let our lock cover them:

  ```toml
  # root Cargo.toml
  members = [ …, "third_party/dotlink", "third_party/aw/crates/aw-inference", … ]
  ```

  ```nix
  # our package policy
  pkgs/ext/dotlink/default.nix  -> fabric.rust.package { projectDir = "third_party/dotlink"; … }
  ```

- **Good:** full unit-level sharing/dedup; one eval; G4 closures and mirrors
  apply; "take a single crate" is a path dep.
- **Bad:** coupling and churn (bump the subtree on every change); the external
  repo's own releases and our vendored copy diverge; licensing/CI duplication;
  we bypass its own flake.
- **When to choose:** when we want the external crates to be **first-class
  members** of our graph (shared cache, one ledger) and we accept the churn.

## 4. Model 3 — provider + ledger (in-graph external source, the fabric-native way)

Keep the repo external, but make its **resolution data first-class** so our
graph can build its units exactly, without reading a derivation at evaluation.

- **Provider descriptor** (produced by the external repo, or by a CI job here
  from the pinned rev):

  ```nix
  # provider: what the crate/workspace is and where its source comes from
  {
    schema = 1;
    ecosystem = "rust";
    repo = "github:abird-ai/aw";
    rev = "<sha>";
    crates = [
      { name = "aw-inference"; version = "0.15.0"; relPath = "crates/aw-inference";
        manifestHash = "…"; }
      { name = "aw-agent-core"; relPath = "crates/aw-agent-core"; … }
    ];
    ledgerSubset = ./ledger/…;   # committed unit descriptors + shards for this repo
  }
  ```

- **Consumed by our repo:**

  ```nix
  # repo flake.nix
  inputs.aw = { url = "github:abird-ai/aw/<rev>"; flake = false; }; # source only
  # providers.nix
  providers.aw = { src = inputs.aw; rev = "<sha>"; ledger = ./ledger/aw; };
  # a package here depends on a crate from the provider
  fabric.rust.package {
    projectDir = "pkgs/srv/foo";
    providerDeps = [ { provider = "aw"; crate = "aw-inference"; } ];
  }
  ```

- **Mechanics:** the **producer** (outside eval) fetches the pinned source,
  reads its manifests, runs cargo, and writes the ledger/shards; eval reads the
  **committed** ledger (no IFD) and builds each unit as an ordinary derivation;
  registry units dedup with ours by content identity.
- **Good:** exact-unit integration without moving the repo; independent release;
  no-IFD; mirrors/adoption apply; cross-repo unit dedup; bounded eval cost.
- **Bad:** requires the fabric/producer in both repos (or a CI generator here);
  more machinery; a rev bump means regenerating the external ledger.
- **This is the model the fabric was designed for** (providers + ledger +
  `externalPackagesFor`); it is the "right" answer for first-party repos we want
  in our graph.

## 5. Model 4 — non-Rust external sources built in our fabric

For `abird-ai` (Node): build it here from a pinned source with our **Node
adapter** (npm lock + platform/ABI identity) and consume its outputs.

```nix
# pkgs/ext/abird-ai/default.nix
fabric.node.package {
  src = inputs.abirdAi;            # flake = false, pinned rev
  packageManager = "npm";          # package-lock.json
  scripts = { build = "npm run build"; };  # allowlisted; default ignore-scripts
  outputs = [ "dist" ];            # static export
  meta.mainProgram = null;
}
# then, e.g., a Rust service consumes the export as a compile overlay:
compileOverlays."frontend-dist" = pkgs.abird-ai;
```

- **Good:** hermetic, cached, dedup with other Node projects, and the export can
  be a **compile overlay** or a packaged site.
- **Bad:** Next.js/Wrangler builds have their own network/config surface; the
  `postinstall`/build scripts must be allowlisted.

---

## 6. Taking a _single crate_ from there into a package here

This is the question the models differ on most.

### 6.1 If the source is in-tree (Model 2)

Trivial — a path dependency / workspace member:

```toml
# in one of our crates
aw-inference = { path = "../../third_party/aw/crates/aw-inference", version = "=0.15.0" }
```

Cargo pulls the crate's intra-repo path deps (`aw-agent-core`, `aw-client`, …)
from the same tree; our fabric builds the whole closure as units.

### 6.2 If the repo is external and consumed as a Cargo **git dependency** (a

native alternative to Model 3's provider)

```toml
# in one of our crates
aw-inference = { git = "ssh://git@github.com/abird-ai/aw.git", rev = "<sha>", version = "=0.15.0" }
```

- Cargo fetches the repo at the rev and resolves the crate **plus its intra-repo
  path deps** from that same checkout — so "one crate" really means "that
  crate's workspace closure" (e.g. `aw-inference` → `aw-agent-core`,
  `aw-client`).
- It pins into our `Cargo.lock`.
- **No-IFD:** our planner cannot read the git checkout (a derivation). This
  works **only** through the fabric's ledger (Model 3): the producer reads the
  git source out-of-eval and commits the resolved units; eval consumes the
  ledger. Plain pure-eval planning cannot see a git dependency.

### 6.3 If the repo is an **opaque flake input** (Model 1)

You can take a single crate **only if the external flake exports it**, e.g.:

```nix
# in abird-ai/aw's flake.nix
packages.${system}.aw-inference = …;   # or a lib.provider = { src; crates = […]; }
```

Otherwise you consume the whole package. To make "single crate" possible for
external repos, the external repo should export either **per-crate packages** or
a **provider** (Model 3) — which is the recommended contract for first-party
repos we own.

### 6.4 Summary table

| desired outcome                            | Model                             | how a single crate is taken                                                                                      |
| ------------------------------------------ | --------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| just run the external binary               | 1 (opaque flake)                  | n/a; whole package                                                                                               |
| use a crate as a library, minimal coupling | 3 (provider) or Cargo **git dep** | provider/git declares the crate; cargo resolves the crate + its workspace closure; our ledger makes it buildable |
| full unit sharing / one graph              | 2 (in-tree)                       | path dep / workspace member                                                                                      |
| consume a web asset                        | 4 (fabric Node)                   | output as a compile overlay                                                                                      |

---

## 7. Cross-cutting implications

- **Cache parity** across repos needs aligned **nixpkgs / crane / toolchain**
  pins; otherwise even Model 1 gives separate caches. The fabric's "one
  canonical library flake, consumers agree on pins when cache parity is wanted"
  covers this.
- **Toolchain divergence:** the first-party repos pin different toolchains
  (`dotlink` = oxalica `rust-overlay` + `rust-toolchain.toml` `1.98.1`; `aw` =
  pinned nixpkgs commit; `abird-health` = rustup + `rust-toolchain.toml`
  `1.95.0`
  - wasm32; our monorepo = nixpkgs rustc). Hosting them needs a **per-capsule
    toolchain contract** and `craneLibFor`; cross-repo cache parity needs a
    converged toolchain. See
    `.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`.
- **No-IFD** is preserved in Models 1, 2, and 4 by construction; in Model 3 by
  the committed ledger; a bare Cargo **git dep without a ledger** is the one
  case that is not pure-eval-plannable.
- **Mirroring/adoption (G10/G11)** applies to any of these repos once they
  expose a provider: our package can be swapped for theirs and vice-versa with
  byte-identical derivations.
- **The external repos already have their own flakes** (dotlink, aw) — a good
  starting point: add a **provider output** (or per-crate packages) to those
  flakes and a thin `abird-ai` flake, so both the "as-is" and the "in-graph"
  paths are available from the same repo.
- **Remote URLs matter:** `aw` and `abird-ai` currently have **bundle** origins;
  flake inputs need a pushable remote (GitHub `abird-ai` org or a reachable
  `git+ssh://`).
- **`aw`'s feature matrix** is large and the root package defaults enable many
  features; a crate-level integration should pin the **exact feature set** it
  needs (the fabric's unit identity already carries resolved features).

---

## 8. Recommendation

1. **Contract first (cheap, unlocks everything):** give each first-party
   external repo (a) a thin/existing flake, and (b) a **provider output** (or
   per-crate packages). This makes both Model 1 (use as-is) and Model 3
   (in-graph units) possible without choosing yet.
2. **`dotlink`** (single crate, single binary): Model 1 is enough if we just
   need the binary; use Model 3 only if we want its units in our cache/shared
   graph.
3. **`aw`** (workspace): use **Cargo git deps + the fabric ledger (Model 3)** if
   we consume its crates as libraries, so the crate + its workspace closure are
   built as exact units and dedup with ours. Model 1 if we only need the `aw`
   binary.
4. **`abird-ai`** (Node app): Model 4 — build it here via the Node adapter from
   a pinned source and consume the export (as a package or a compile overlay for
   a service).
5. **Do not import (Model 2)** unless we specifically want a first-party project
   to become a **first-class member** of our workspace (shared cache/one ledger)
   and accept the subtree churn.
6. **Push `aw`/`abird-ai` to real remotes** so any of these models can reference
   them.

---

## 9. Model 2 in detail — what changes in their build

Two ways to "subtree", with very different change sets:

- **(A) Subtree the source but keep it its own workspace/capsule** (opt out + a
  separate build, or a path dep for binaries). Minimal manifest changes.
- **(B) Absorb its crates into our root workspace** (one lock, one resolver).
  Real manifest changes and a shift in their dependency resolution.

### 10.1 Always required (Nix side)

- Provide **our** build definition for it (a policy/`default.nix` calling our
  helper); their `flake.nix`/`flake.lock` become unused by us (keep them for
  their standalone CI; nested flakes are ignored by Nix, but exclude the nested
  `flake.lock` and build outputs from our source filter).
- Move native inputs to our policy/native registry; move their tests/checks into
  our checks.
- Exclude `target/`, `dist/`, `.next/`, `node_modules`, `.git` from the source.

### 10.2 Kept as its own workspace (A) — minimal changes

- **`dotlink` has no `[workspace]` table.** Putting it under our workspace root
  requires either adding `[workspace]` to its manifest (opt out) or listing it
  in our `members`/`exclude`; otherwise cargo errors with "current package
  believes it's in a workspace when it's not".
- **`aw` already has `[workspace]`**, so it opts out naturally.
- Their own `Cargo.lock` is authoritative only when built from their dir; the
  moment we **path-depend** on one of their crates, **our** lock covers it — so
  versions still unify with ours and exact pins can conflict.
- Cargo **cannot link a prebuilt rlib from a different resolution**, so only
  **binaries/artifacts** cross a capsule boundary; a library must join our
  resolution.

### 10.3 Absorbed into our workspace (B) — real changes

`dotlink`:

- add to `members` (or opt out);
- **remove `[profile.release]`** (`lto = "thin"`, `codegen-units = 1`,
  `strip = "symbols"`) — profiles are **workspace-root-only**, a member's
  profile is ignored with a warning; or hoist it to our root (global effect);
- drop/align `rust-toolchain.toml` (channel `1.98.1`): Nix uses our rustc, so
  ours must satisfy `edition = "2024"` (>=1.85) and ideally 1.98.1;
- its deps (`tokio`, `axum 0.8`, `reqwest 0.12`, `ngrok 0.19`, `uuid`, …) unify
  with our workspace.

`aw`:

- remove `[workspace]`, `resolver = "2"`, `default-members`;
- move/merge `[workspace.dependencies]` **exact pins** (`serde = "=1.0.228"`,
  `serde_json = "=1.0.145"`, `thiserror = "=2.0.17"`) into ours or inline them —
  reconcile with our lock (**duplicate-version risk** if ours differ);
- remove `[profile.release]` (or hoist);
- **`.cargo/config.toml` (`[resolver] incompatible-rust-versions = "fallback"`)
  stops applying** — cargo config is discovered from the CWD, not per-package —
  so resolution behavior changes;
- resolver becomes **v3** (was 2); `rust-version = "1.88"` must be <= our rustc;
- the root package's large `[features]` and optional deps stay, but **feature
  unification with our workspace can enable extra features** — which conflicts
  with the G10/G11 "standalone == merged" goal;
- intra-repo path deps (`../aw-agent-core`) keep working (relative layout
  preserved).

### 10.4 Node (`abird-ai`)

- No Cargo changes. Only our Node policy: build command (replace or invoke
  `scripts/build-verified.sh`), postinstall allowlist, Node >=22.13 toolchain,
  `.npmrc`/`.openai` handling, declared env/network (wrangler/drizzle/fonts),
  outputs (`dist`/`.next`/`static-worker`), and exclusions.

### 10.5 The semantic warning

Absorbing and unifying changes **their** dependency resolution (versions,
features, resolver, lost profiles/config), so their in-tree build can differ
from their standalone build — the exact property the G10/G11 design tried to
preserve. Therefore:

- **binary** (`dotlink`, the `aw` CLI) -> (A) separate capsule preserves their
  resolution with minimal changes;
- **library** (`aw-inference`) -> must join our resolution (B) and accept the
  shift, or stay external with the ledger provider (Model 3) and preserve its
  resolution.

---

## 10. Open questions

- Provider schema: minimal fields (`ecosystem`, `repo`, `rev`, `crates[]`,
  `ledgerSubset`) vs per-crate packages — settle before adding providers.
- Who runs the producer for an external repo: that repo's CI, or a job here on
  the pinned rev?
- Feature-set contract for `aw` crates consumed as libraries (which features,
  and how they compose with our resolution).
- Whether `abird-ai` should also expose a provider/export for a wasm/JS bundle
  used by other projects.
- Licensing/CI duplication if any project is imported in-tree.
