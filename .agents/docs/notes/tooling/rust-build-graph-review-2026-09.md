# Rust build-graph (Design L) fresh review — 2026-09

Independent, fresh-context review of the whole Design L series before starting
the Design F worktree.

- Target: `origin/master..master`, base `03fc5023`, head `a43b811d` (9 commits:
  `0a75ea13` shared workspace deps/member artifacts → `a43b811d` Cargo feature
  normalization).
- Diff artifact used by reviewers: `tmp/dag-review.diff`.
- Verdict (all three completing lanes): **OK with notes — no blocker, no
  confirmed correctness regression.**
- The findings below are recorded, not yet dispositioned; several are cheap and
  could land before Design F, others are naturally folded into F.

## Method

Four lanes (one failed and was re-run):

1. correctness / bugs / regressions (static, crane source cross-check),
2. design quality (composability, scale, future-proofing, API intuitiveness),
3. adversarial / boundary + feature-normalization exactness + doc claims,
4. empirical verification with shell (no-IFD eval, derivation introspection,
   closure checks, degradation harness, join probe, `Cargo.lock` diff).

The first adversarial child was killed by a store-wide `find` (no output) and
re-run bounded; it must never scan `/nix/store`.

## Verified to hold (with evidence)

- **No IFD**: all six packages eval under
  `--option allow-import-from-derivation false`; no `readDir`/`import` in the
  new code; eval-time reads stay behind `builtins.isPath` guards.
- **One shared `.rs`-independent base**: every member resolves to the same
  `abird-rust-workspace-deps` drv; dirty-vs-committed eval keeps that base drv
  identical while the package drv changes; the dummy source contains 0 `.rs`
  files.
- **`memberLayer` is artifacts-only and does not leak**: agent closure ≈53.8 MB,
  references only glibc/gcc-lib; `nix path-info -r` shows no `-build` layer and
  no workspace base.
- **Locality**: `nix build --dry-run .#abird-host-manager` plans only manager
  source + manager layer + manager package; base and agent layer are reused.
- **Artifact chaining** is correct for 0/1/N parents (`.prev` recursion), so a
  single internal dep needs no join.
- **Degradation**: a dependent rolled back to `useWorkspaceDeps = false` is
  dropped from the chain and still evaluates.
- **Feature normalization**: `Cargo.lock` unchanged; the root
  `[workspace.dependencies]` union exactly equals the union of the removed
  per-member lists; only additive widening (wrecking-ball gains tokio
  `io-util`/`net`/`process`).

## Findings

### P1 — address before scaling to the 24-member Abird workspace

- **P1-A. The shared `--workspace` base is an unfiltered, repo-wide single point
  of failure.** `mkSharedRustDepsBase` takes no member list, no host filter, and
  no native-input seam, and unions every member's normal **and**
  dev-dependencies. One member that needs a platform/native input (or a
  different host) makes the single base — and therefore every member's layer —
  unbuildable. Fix: add a seam now (`members ? rustWorkspaceMembers src`,
  `nativeBuildInputs ? []`, `buildInputs ? []`) emitting `-p`/`--exclude`;
  Design F's planner needs this filter anyway.
- **P1-B. Mode selection is silent and unobservable.** A glob member, a
  `projectDir` spelling that misses the root manifest, or a dependent without a
  `memberLayer` silently drops Design L for one package or **all** packages,
  with no eval warning, log line, or passthru signal (W11's `rustWorkspacePlan`
  is not implemented). Fix: `lib.warn` at each degrade trigger and expose the
  resolved mode in `passthru`.
- **P1-C. Docs contradict the code on feature normalization.** The same series
  lands it, but `design-l-implementation-2026-09.md`,
  `rust-build-graph-decision-2026-09.md`, and
  `rust-workspace-build-graph-2026-09.md` still call direct normalization
  deferred/"decide whether", and `cargo-workspace-2026-04.md` says members
  should declare their own feature needs — the opposite of the new invariant.
  Fix: mark direct normalization landed (transitive-union residual still open)
  and state the "union at root, members bare `{ workspace = true }`" policy.

### P2 — robustness / efficiency / quality

- **P2-a. Per-package `buildAttrs` leak into the artifacts-only layer.**
  `memberLayer` passes `craneCommonAttrs`, so a member's `postInstall`,
  `nativeBuildInputs`, and env reach `cargoBuild`. Benign today only because
  manager's `postInstall` is `-x`-guarded. Fix: pass a compile-only filtered
  attrs set to `cargoBuild`.
- **P2-b. `internalDeps` is validated twice and independently**, so the guard's
  error message is not guaranteed (a raw Nix type error can win), and the guard
  is not forced at all in the `craneLib == null` fallback (silently ignored).
  Fix: compute one validated list and derive both `resolvedDeps` and
  `dependencyMemberLayers` from it; force the guard on every shape.
- **P2-c. Normalize/dedupe before comparison.** `resolvedDeps` dedupes raw
  strings before `normalizeMemberPath`, so `./x` and `x` can duplicate into the
  member rewrite; duplicate `internalDeps` also reach the join twice. Fix:
  normalize then `unique`, and dedupe layers.
- **P2-d. Workspace mode rejects a `cargoLock` that is a derivation/table**
  (throws unless `cargoLockContents` or a path lock). Not triggered in-repo;
  crane's contract allows a derivation. Fix: thread the resolved lock through.
- **P2-e. Deploy-time test-target recompile.** `buildPackage` keeps
  `doCheck = true` by default, so bridge/wrecking/hello-rust run `cargo test` in
  the deployed build, but the artifacts-only layer never primed test targets
  (`--no-run`), losing the test cache the old `-deps` provided; `cargoFmt` also
  does not inherit the layer. Correct, but a measurable regression vs the legacy
  path. Fix: set `doCheck` in `buildAttrs` or document the trade.
- **P2-f. The normalization invariant is unguarded.** Nothing prevents a member
  from re-declaring shared-dep features and silently re-splitting the cache.
  Optionally add an eval assertion in `lib/flake/tests`.
- **P2-g. No test coverage for the graph properties.** No assertion that the
  members share one base drv, have distinct layers, degrade without throwing, or
  that the fan-in join evaluates. Add cheap eval-level tests.
- **P2-h. `mkCargoArtifactsJoin` is the only full-archive node and is dead
  in-repo** (no member has ≥2 internal deps), so a regression cannot be caught;
  a symlink-only join may also be viable instead of materialising a full
  archive. Probe when the first 2-edge member appears.

### Notes

- **".rs-stable" is narrower than stated**: adding/removing a file under a
  member's `src/lib.rs`, `src/main.rs`, or `src/bin/` changes the shared base
  drv (crane `readDir`s those dirs at eval time), so it is not "only the edited
  member changes"; editing `.rs` **contents** is stable.
- `projectDir = "."` (root-package member) is unsupported by the source filter
  (pre-existing; not reachable today).
- Hardcoded `pname = "abird-rust-workspace"` in the generic helper; the
  `passthru` contract is flat/undocumented; the W8 dummy ladder is duplicated in
  `mkTrunkProject` and `mkRustDerivation`; the `useWorkspaceDeps` arg doc
  default does not match its expression.
- `exportCargoArtifacts` referenced in a note does not exist in the tree.
- A doc code span is split across a newline (`rust-workspace-build-graph` §Steps
  3), which `deno fmt`/markdownlint may flag.

## Open questions

- Which P1/P2 items land in the current DAG branch vs the Design F worktree?
  Candidates for "now": P1-C (docs) and the `.rs`-stability caveat (doc-only);
  P2-a/b/c (small robustness); P2-g (cheap eval tests). Candidates for F: P1-A
  (member/native-input seam), P1-B (diagnostics/plan output), P2-h (join).
- Confirm the additive tokio widening for `nats-wrecking-ball` is intended.
