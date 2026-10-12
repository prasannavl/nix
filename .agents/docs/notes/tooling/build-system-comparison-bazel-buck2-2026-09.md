# Build-system comparison — our Nix unit-DAG fabric vs Bazel and Buck2 (2026-09)

Scope: compare the repo's build/cache architecture (the landed Design L, the
Design M / G4 designs, and the multi-ecosystem unit-DAG fabric) against
**Bazel** (Google, open source) and **Buck2** (Meta, open source). Focus is
architectural, not benchmark. Bazel/Buck2 are large, version-dependent systems;
specifics below are hedged where they change between releases. Buck1 (legacy) is
out of scope.

Companion docs: `.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md`,
`.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`,
`.agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md`.

---

## 1. TL;DR verdict

- **Bazel and Buck2 are more mature, more fine-grained, and better at very large
  polyglot monorepos** — especially remote execution, action-level caching,
  query tooling, and platform/configuration transitions.
- **Our fabric is not a worse Bazel; it is a different point in the design
  space**: it keeps each ecosystem's **native resolver as the source of truth**,
  commits the resolver's output as a **ledger** (no IFD), and uses the **Nix
  store + binary cache** as CAS/remote cache with hermetic sandboxing — while
  adding a first-class **mirror/standalone-package** story and inheriting
  **NixOS packaging/deployment**.
- **The single most important convergence:** Bazel/Buck2 do **not** natively
  resolve package-manager graphs either. Their Rust/Go/Python support is driven
  by **generators** — `rules_rust`'s `crate_universe`, Gazelle for Go,
  `rules_python`'s lock importers, and Meta's **reindeer** for Buck — which
  ingest `Cargo.toml`/`Cargo.lock`/`go.mod`/lockfiles and emit build files. That
  is **exactly** our "capture the resolver, commit it, feed the build" escape.
  Our design makes that a **core mechanism** rather than a per-ecosystem rule
  chore.
- **Net:** if the goal were "fastest possible fine-grained polyglot build with
  remote execution at Google/Meta scale", Bazel/Buck2 win. If the goal is "one
  hermetic, Nix-native, multi-ecosystem, mirrorable, packaging-integrated build
  system for this repo with minimal hand-maintained graphs", our fabric is the
  better fit.

---

## 2. The three systems in one paragraph each

**Our fabric.** Nix derivations are the action graph. A **pure-eval planner**
reads manifests/locks; a **resolver (producer)** captures each ecosystem's own
resolution (cargo/go/npm/deno/uv/cmake) and commits it as **content-addressed
units** (the ledger) plus per-`(capsule, purpose, target, profile)` **shards**.
Evaluation never reads a derivation (no IFD); each unit is a hermetic Nix
derivation with an ABI-bearing identity; the Nix store + binary cache is the CAS
and remote cache; per-capsule **modes** (`unit`/`native`/`legacy`) fail closed.
Packages can be **mirrored** into standalone flakes and adopted back by a
**provider** seam.

**Bazel.** Skyframe evaluates a Starlark graph (`BUILD`/`MODULE.bazel`, bzlmod)
into an **action graph**; actions are hermetic and sandboxed, with explicit
inputs/outputs. It has a **CAS + action cache**, a **disk/remote cache**, and
**remote execution** (REAPI). It has first-class **platforms/constraints**,
**toolchains**, and **configuration transitions**. Third-party ecosystems
integrate via rules and **generators** (crate_universe, Gazelle, pip lock
importers). Query tooling is strong (`query`/`cquery`/`aquery`, BEP/BES). It is
a _build system_; packaging/deployment are not its concern.

**Buck2.** Meta's Rust-hosted rewrite of Buck. Starlark (`BUCK`), targets →
rules → providers → analysis graph → action graph, a **daemon**,
**content-addressed caching**, **remote execution** (REAPI),
**configurations/transitions**, platforms/toolchains, **dynamic dependencies**
(deps discovered during execution), plus `query`/`uquery`/`audit`/`bxl`
scripting and log tooling. Similar ecosystem integration story (e.g.
**reindeer** generates Buck rules from Cargo). Also build-only.

---

## 3. Axis-by-axis comparison

| axis                        | our fabric                                                                                                                                                              | Bazel                                                    | Buck2                                                                    |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| Unit of work                | ecosystem unit (crate/package/object/wheel/tree) → Nix derivation                                                                                                       | action                                                   | action                                                                   |
| Resolution source           | **the ecosystem's own resolver**, captured                                                                                                                              | Starlark graph + generators (crate_universe/Gazelle/pip) | Starlark graph + generators (reindeer)                                   |
| Handwritten dep graph       | manifests only (no BUILD for third-party)                                                                                                                               | BUILD files (+generated)                                 | BUCK files (+generated)                                                  |
| Eval vs build               | pure eval + committed ledger; **no IFD**                                                                                                                                | Skyframe analysis; actions hermetic                      | analysis + action graph; **dynamic deps** allow execution-time discovery |
| Invalidation key            | derivation hash (unit identity)                                                                                                                                         | action key / CAS digest                                  | action key / CAS digest                                                  |
| Cache                       | Nix store + binary cache                                                                                                                                                | CAS + disk/remote cache                                  | CAS + remote cache                                                       |
| Remote builds               | **incremental at derivation granularity** (`--builders`/`--build-host` + persistent store/binary cache, e.g. nixbot -> `pvl-x2` + Harmonia); no REAPI/action scheduling | **REAPI** (mature)                                       | **REAPI** (mature)                                                       |
| Platforms/toolchains        | `system` + explicit target/ABI + toolchain contracts (coarser)                                                                                                          | **platforms/constraints/toolchains + transitions**       | **configurations/transitions**                                           |
| Polyglot                    | adapters over native resolvers                                                                                                                                          | rules per language (large ecosystem)                     | rules per language                                                       |
| Query/observability         | `nix derivation show`, `rustPlan`/`fabric-plan` (planned); no query language                                                                                            | **query/cquery/aquery, BEP/BES**                         | **query/uquery/bxl, logs**                                               |
| Packaging/deploy            | **NixOS modules/services/images**                                                                                                                                       | none                                                     | none                                                                     |
| Cross-repo/mirror           | **first-class** (layout-preserving mirrors, provider adoption)                                                                                                          | external repos (http_archive/bzlmod)                     | external cells/repos                                                     |
| Hermeticity                 | Nix sandbox; declared native/env/overlays                                                                                                                               | sandboxed actions                                        | sandboxed actions                                                        |
| Daemon/incremental analysis | none (per-invocation eval)                                                                                                                                              | server + Skyframe                                        | **daemon**                                                               |
| Proven scale                | small (this repo)                                                                                                                                                       | Google-scale                                             | Meta-scale                                                               |

---

## 4. Deep dives

### 4.1 Dependency resolution — the convergence

Bazel/Buck2 deliberately do **not** run `cargo`/`go`/`pip` at build time to
resolve third-party graphs. Instead:

- `rules_rust` **crate_universe** ingests `Cargo.toml`/`Cargo.lock`, resolves
  with cargo, and generates repositories with the correct per-crate
  **features**.
- **Gazelle** generates Go `BUILD` files from `go.mod`.
- `rules_python` imports pip lock/hashes; `rules_jvm_external` imports Maven.
- Meta's **reindeer** generates Buck rules from Cargo.

So both systems already accept that **the ecosystem resolver must be captured**,
and they pay for it with **generators + per-ecosystem rules**. Our fabric takes
the same insight and makes it uniform: one **producer protocol** and one
**ledger** for all ecosystems, read by pure Nix eval. The difference is _where_
the captured resolution lives (BUILD/BUCK files + rules vs a content-addressed
ledger) and _who_ maintains the integration (rule authors vs a generated plan).

Consequence: our design has **no BUILD/BUCK file for third-party deps** and no
per-ecosystem rule to maintain; Bazel/Buck2 have a richer, but heavier,
integration surface.

### 4.2 Eval-vs-build separation

- **Bazel**: Skyframe does the "analysis phase" (evaluate Starlark to an action
  graph) before actions run; actions cannot read undeclared inputs. This is the
  analogue of our **no-IFD** rule and our pure-eval planner.
- **Buck2**: analysis + action graph, plus **dynamic dependencies**, which allow
  a rule to discover inputs _during execution_ (in a controlled way). This is
  precisely the capability our **no-IFD** rule forbids for evaluation (we moved
  that discovery into the committed ledger instead). Buck2 gets more power (e.g.
  C++ header discovery) at the cost of more complex, less purely deterministic
  analysis.
- **Our fabric**: the "analysis phase" is the producer (outside eval) and the
  committed ledger/shards; eval only reads committed data. This is closest to
  **Bazel's analysis cache**, but materialized as files instead of an in-memory
  Skyframe.

### 4.3 Incrementality and invalidation

All three invalidate by content hash of declared inputs:

- Nix: derivation hash = f(inputs, build recipe); store paths are content
  addressed. Our unit-DAG makes the derivation ≈ the action, so granularity is
  comparable to Bazel/Buck2 for compiled units; for pure-JS/Deno units the
  "unit" is a file tree.
- Bazel/Buck2: action key = f(command, inputs digests, env, platform); the
  action cache maps keys to CAS outputs.

The practical difference is **analysis cost**: Bazel/Buck2 keep a warm daemon
(Skyframe / Buck2 daemon) so re-analysis is incremental and fast; our design
re-runs Nix evaluation each time (a documented weakness). Our ledger makes the
_correctness_-critical part cheap to read but does not make eval itself a
daemon.

### 4.4 Cache and remote builds (and what "remote" buys)

- **Nix**: CAS = the store; remote cache = binary cache (substituters);
  distributed builds = `--builders` / a `--build-host` (whole derivations run on
  remote machines). **Remote builds are already incremental at derivation
  granularity**: Nix computes the graph (on the client) and builds only the
  derivations not already present in the client store, a remote builder's store,
  or a substituter — an unchanged graph builds nothing, and missing derivations
  are distributed/parallelized. In this repo, nixbot's `--build-host` (e.g.
  `pvl-x2`, from `config.builders`) builds on a persistent store and serves a
  signed **Harmonia** binary cache, so the same outputs are substitutable by
  other machines too.
- **The catch is granularity, not incrementality.** A derivation is _atomic_ —
  there is no partial resume. So a coarse derivation that changes (Design L's
  shared base) is rebuilt whole, while a fine-grained one (Design G4's
  per-member closure base, or a unit-DAG unit) shrinks what the remote builder
  must rebuild. **Evaluation is not offloaded**: the client evaluates the graph
  (reading the committed ledger) and dispatches derivations, so a large unit-DAG
  raises client-side eval cost even though builds run remotely.
- **Bazel/Buck2**: CAS + action cache + **REAPI** remote execution with
  input/output materialization, scheduling, and "build without the bytes".

The gap vs Bazel/Buck2 is therefore **not** "no remote incrementality" — it is
(a) **action-level** scheduling/REAPI with byte-streaming, and (b) a warm
**daemon** doing incremental _analysis_. Nix gets the same content-addressed
reuse at derivation granularity, with a coarser client-side analysis step.

### 4.5 Platforms, toolchains, transitions

- Bazel: `platform`/`constraint_value`/`toolchain` + **configuration
  transitions** (split/attach, Starlark transitions) let one target build for
  several platforms in one invocation.
- Buck2: **configurations/transitions**, platforms/toolchains.
- Our fabric: `system` plus explicit **target triple / GOOS-GOARCH / node ABI /
  Python tag / C++ ABI** in unit identity, and per-target shards; host vs target
  roles. Coarser (no split transitions, no per-target select), but honest and
  sufficient for the repo. We borrow the _identity_ discipline, not the
  _transition_ machinery.

### 4.6 Cross-repo, mirrors, external deps

- Bazel/Buck2: external repos (`http_archive`, `git_repository`, bzlmod
  modules/cells) are fetched inputs; there is no built-in "standalone package
  flake" or "adopt a package back" story — that is our **G10/G11** (mirrors +
  `externalPackagesFor` + the `base`/provider seam).
- This is a genuine differentiator: our design treats a package as
  **simultaneously in-repo and independently buildable/mirrorable** with
  byte-identical derivations, which Bazel/Buck2 do not target.

### 4.7 Polyglot and ecosystem integration

- Bazel/Buck2 have **first-class rules** for C++/Java/Go/Python/Rust and more,
  maintained by large communities; but each ecosystem needs its rule set and its
  generator, and hermeticity requires vendoring/fetching under their model.
- Our fabric has **one core + thin adapters** over native resolvers, so
  "supporting a new ecosystem" means writing an adapter, not a rule ecosystem.
  Trade-off: less depth per ecosystem (no equivalent of rules_rust's advanced
  C++ interop or Bazel's Java toolchains).

### 4.8 Query, introspection, observability

- Bazel: `query` (target graph), `cquery` (configured graph), `aquery` (action
  graph), BEP/BES event streams, `bazel mod`.
- Buck2: `query`/`uquery`, `audit`, **`bxl`** (Starlark scripting over the
  graph), rich logs, critical-path analysis.
- Our fabric: `nix derivation show` (graph), `nix-store -q` (refs/closure), and
  the planned `rustPlan`/`fabric-plan` output (closures, units, shards, degrade
  reasons). **We are materially weaker here** — no query language, no action
  stream. Borrowing a `fabric query` + a BEP-like event stream is a concrete
  improvement to consider.

### 4.9 Hermeticity and correctness

- All three sandbox actions and require declared inputs; all three hash inputs.
- Nix adds **signed binary caches** and a **content-addressed store**;
  Bazel/Buck2 add **action-cache poisoning** protections and remote-execution
  verification.
- Our extra discipline: **committed resolution + fail-closed stale shards**, and
  **no mutable cache in the correctness path (production)**.

### 4.10 Packaging and deployment

- Bazel/Buck2 produce build outputs; packaging, services, images, and host
  config are out of scope (you delegate to another system).
- Our fabric lives inside **Nix**, so the same graph feeds **NixOS modules,
  services, VM/OCI images, and host configuration** — the repo's actual
  deliverables. This is a structural advantage for _this_ repository.

### 4.11 Developer experience

- Bazel/Buck2: BUILD/BUCK files + rule knowledge; powerful but steep; strong
  tooling once learned.
- Our fabric: a manifest (+ an optional policy file) is a package; a
  **regeneration command** (`fabric-plan generate`) must be run on
  resolution-affecting edits (like a lockfile); no BUILD files for third-party
  deps; fail-closed shards give clear errors. Lower rule-authoring burden, new
  "regenerate the ledger" ceremony.

### 4.12 Scale

- Bazel/Buck2 are proven at Google/Meta scale (millions of actions, RE).
- Our fabric is **unproven at scale**; the risks are Nix eval cost, ledger size,
  and the per-capsule mode qualification. This is the honest gap.

---

## 5. Where our design is weaker (be explicit)

1. **No action-level remote execution (REAPI)**; Nix remote builds are
   derivation-granular and less tooled (no scheduler, no byte-streaming).
2. **No daemon / incremental analysis**; Nix eval cost per invocation.
3. **Weak query/observability** (no query language, no BEP).
4. **No configuration transitions / `select`**; platform modeling is coarser.
5. **Unproven at scale**; ledger/eval costs unmeasured.
6. **Adapter depth** per ecosystem is less than mature rule sets.

## 6. Where our design is stronger / genuinely different

1. **Native resolvers as the single source of truth**; no BUILD/BUCK files for
   third-party deps; no rule maintenance per ecosystem.
2. **No IFD with exact resolution** via a committed ledger — the same insight as
   crate_universe/reindeer, but uniform and first-class.
3. **First-class mirrors + adoption (G10/G11)**: a package is
   standalone-buildable and byte-identical when adopted back.
4. **Nix-native packaging/deployment** (NixOS modules/services/images) in the
   same graph.
5. **Fail-closed per-capsule modes**: an unsupported unit degrades one capsule,
   never the repository.
6. **No mutable cache in the production correctness path.**

## 7. Could we just use Bazel or Buck2 instead?

Honest assessment for _this_ repo:

- Bazel/Buck2 excel at the build, but the repo's deliverables are **Nix
  outputs** (hosts, services, modules, images, secrets wiring). Adopting
  Bazel/Buck2 would either (a) replace only the build half, leaving Nix for
  packaging (two build systems, two dependency graphs, coordination churn), or
  (b) require rebuilding the repo's packaging/deployment in Bazel/Buck2 terms (a
  large migration away from Nix).
- Their Rust/Go/Python support would still need generators (crate_universe/
  Gazelle/reindeer), i.e. the same "capture the resolver" work we are doing —
  plus BUILD/BUCK files and rule maintenance.
- Their strengths (RE, query, transitions, daemon) matter most at a scale this
  repo has not reached; the multi-ecosystem polyglot + mirroring + packaging
  needs are better served by the fabric.

**Conclusion:** not a replacement; rather, Bazel/Buck2 are the reference designs
for the _build half_, and our fabric should **borrow their best ideas**: a
`fabric query`/`fabric aquery`-like introspection, a BEP-like event stream,
explicit platform/toolchain identities (already partly present), and — if scale
demands it — an action-level remote-execution backend.

---

## 8. What to borrow from Bazel/Buck2 (candidate backlog)

1. **Query surface**: `fabric query` (unit graph), `fabric aquery`
   (shard/action), `fabric cquery` (per-target/profile).
2. **Event stream**: a BEP-like JSON stream over the plan/build for CI tooling.
3. **Config/platform identity**: make target/ABI/toolchain identity first-class
   in the plan (partly done), and consider named platform sets.
4. **Critical-path / bottleneck reporting** (Buck2-style) over the unit graph.
5. **Optional remote-execution backend** (REAPI) behind the executor interface,
   if the executor abstraction already isolates `unit → derivation`.
6. **Analysis cache**: persist plan evaluation results to avoid re-eval (the
   ledger is the first step).

---

## 9. Caveats

- Bazel/Buck2 internals are version-dependent; treat version-specific mechanics
  (dynamic deps, bzlmod, BXL, RE details) as indicative, not exact.
- No benchmarks were run; the comparison is architectural.
- Buck1 (legacy) and non-open-source internal systems (Google Blaze, Meta's
  internal Buck) are out of scope; Bazel and Buck2 (OSS) are representative.
- Our side of the comparison is the **design**, not a built system; the fabric
  is not implemented.
