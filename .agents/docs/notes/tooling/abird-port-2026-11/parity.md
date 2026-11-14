# Final shared library/package parity

## Final integrated snapshot and qualification boundary

The reviewed implementation is integrated into main in the signed series listed
in [the overview](README.md#main-integration). Every manifest target still
matches main bytes/modes; fingerprints and classifications are unchanged.
Candidate HEAD/baseline fields below retain their original snapshot meaning, not
the later delivery tip. Integration is not runtime promotion.

**Every `lib/` / `pkgs/` union path has an explicit disposition. No unclassified
generic transfer gap remains in this inventory. This is not a readiness or
test-success claim.**

- Frozen source **S**: `070011e2923ebdb16370bbfbba31876c47584002`.
- Original frozen audit baseline **D**:
  `2d9f5d5caefd80c1955b298475289d6bc697649a`. Every JSON `baseline` field still
  refers to D; it is **not** the current candidate HEAD.
- Current detached candidate HEAD / integration base:
  `e7f3ef479c42c8cfa89668230782809cb3a3fb3e`.
- Candidate **C**: actual worktree bytes over that integration base, not
  HEAD/index contents.
- Final actual-filesystem snapshot: **2026-11-14 13:40:39 UTC**.
- **Zero provisional paths.** The final frontend blobs match the independent
  review that closes both ordering/sparse-PATH P2 findings; the native admission
  P2 is closed at all twelve matching repair hashes.
- All **1,644 union rows** were independently rechecked, including a fresh
  double read/hash of all **1,117 candidate files**, original source/baseline
  metadata, modes and literal symlink targets. KiloCLI removal changes
  `pkgs/tools/kilo-cli/default.nix` and its registration in `pkgs/manifest.nix`;
  all other **1,642 rows** are unchanged from the preceding export. Only the
  wrapper changes parity state. Every frontend/native review hash is unchanged;
  this refresh does not repeat semantic review.
- This final code snapshot is **not runtime/VM certification**. The
  coordinator's final canonical gates passed on the current integration base;
  see the separate [verification report](verification.md).

[parity.json](parity.json) exports **all 1,644 rows, including equal files**,
source/candidate/baseline Git blob IDs, types, modes, literal symlink targets,
exact-path reasons, portable evidence, aliases, review boundaries and integrity
data. It replaces preliminary “owned by worker” and “missing generic”
dispositions with observed implementation, retained policy, coherent scope
decisions and the reviewed frontend/native hardening adaptations.

Evidence references are repository-relative code/docs, immutable
source/destination commits, this report, the
[452-commit ledger](commit-ledger.md) / [JSON ledger](commit-ledger.json), and
retained historical policy notes. No ignored run-report link is required to
understand a final disposition. The implementation/review reports were
reconciled as working evidence; their older source-equality totals and test
results are not silently promoted to this snapshot.

The current integration base includes destination commits
`47bb09380e10dcf25ea7c50df16cf375a5d7b053` (KiloCLI removal),
`505c727e2323ce888ad2d4201ce5352c9c4516cb` (VS Code Kilo removal), and
`e7f3ef479c42c8cfa89668230782809cb3a3fb3e` (Dotlink 0.17.0). Of their eight
changed paths, only the two Kilo package paths are in this denominator. The
other six paths are outside this shared-tree parity claim. Current destination
removal policy supersedes the earlier source-equality disposition.

## Denominators and integrity

| Raw path scope | Equal bytes/type/mode | Different common | Source-only | Candidate-only |    Common |     Union |
| -------------- | --------------------: | ---------------: | ----------: | -------------: | --------: | --------: |
| `lib/`         |                   527 |               22 |          49 |             64 |       549 |       662 |
| `pkgs/`        |                   457 |               33 |         478 |             14 |       490 |       982 |
| **Total**      |               **984** |           **55** |     **527** |         **78** | **1,039** | **1,644** |

- S has **1,566** paths; C has **1,117**. Raw same-path equality is **984/1,039
  common paths**, not 984/1,644 and not “all shared code identical.” All **660**
  non-equal/presence rows have individual reasons.
- Initial frozen S/D `lib/` + `pkgs/` union was **1,640**: 729 equal, 93
  different, 744 source-only, 74 destination-only. Four new destination paths
  enlarge the final union: two OpenDesign check/doc files, the Graphiti runner,
  and the native-admission regression.
- The source inventory comes from recursive `git ls-tree`. Candidate names are
  tracked plus nonignored untracked paths under the two roots, with absent files
  removed; actual regular-file bytes and `lstat` modes are hashed. Ignored
  build/cache products and directories are not source-manifest entries.
  Intent-to-add/staging does not determine content identity.
- The final independent rehash verified the entire **1,644-path union** against
  S, original D and the actual candidate filesystem. Since the 13:10:20 export,
  only `pkgs/tools/kilo-cli/default.nix` (removed) and `pkgs/manifest.nix`
  (single registration deletion) changed. The latter was already different from
  S, so only the wrapper changes state, from equal to source-only. All other
  **1,642 complete rows** are unchanged; restoring just those two rows
  reproduces both previous canonical fingerprints. A second full filesystem read
  was stable. JSON `final_recheck` records this verification and the prior
  fingerprints, not merely current-report self-consistency.
- **Zero common-path type/mode changes**, including zero executable-bit-only
  changes. No gitlinks or special files. Source modes: 1,535 regular / 25
  executable / 6 symlink; candidate: 1,090 / 21 / 6. Modes are Git-normalized
  `100644`, `100755`, `120000`, not an ownership/ACL audit.
- **Six symlinks match literal targets**, without dereferencing, including the
  deliberately nonexistent absolute fixture target. Their exact pairs are below.
- Integrity checks require the complete sorted union, unique paths, valid
  source/candidate hashes, nonempty reasons/evidence, all 660 exceptions
  classified, all ten aliases backed by observed files, and current-byte
  rechecks. They do not certify every line's semantics.

### Manifest fingerprint

Final snapshot manifest SHA-256:

```text
8bcdbf793f765a51a70bfad916df53a879449ca4d87ce08b5c8ee98c4b316afb
```

Classified-rows SHA-256:

```text
e55910b8730b64e1e376053472d0dd5401b72676c3995ce043f5172a6dce54ba
```

This is SHA-256 of canonical JSON over the sorted
`[{path, source, target}, ...]`, with `sort_keys=True`, `separators=(",", ":")`,
`ensure_ascii=True`, UTF-8, no trailing newline. Source/target objects contain
Git `mode`, `kind`, `oid` and literal `link_target` when applicable. JSON
formatting does not change the fingerprint. `classified_rows_sha256` separately
covers all complete rows/reasons. Neither field is a circular hash of its
containing file.

**This fingerprint includes the final reviewed frontend blobs and all other
observed candidate files.** It identifies this exact code snapshot, not the
outcome of canonical gates or installed-runtime qualification. Any later code
change requires a fresh filesystem comparison and fingerprint; a matching HEAD
or internally consistent JSON is insufficient.

| Symlink path under `lib/flake/rust/tests/fixtures/` | Literal target in both trees           |
| --------------------------------------------------- | -------------------------------------- |
| `closures/cancelled-symlink/shortcut`               | `a`                                    |
| `closures/lock-symlink/Cargo.lock`                  | `../lock-target/Cargo.lock`            |
| `closures/root-symlink/Cargo.toml`                  | `manifest.toml`                        |
| `closures/source-link`                              | `regular`                              |
| `closures/symlink/a/linked-input`                   | `Cargo.toml`                           |
| `source-scope/symlink/members/leaf/src/foreign`     | `/nonexistent-rust-source-scope-probe` |

## Relocations and alternate composition

Destination commit `48b56e1d741f7b398ad50e5712645053dbb8935d` and
`.agents/docs/design-patterns/external-source-units.md` establish
management-style ownership. **Do not undo it for pathname parity.**

| Source path                                                          | Candidate path                                  | Rechecked result                                                                                                       |
| -------------------------------------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `pkgs/ext/agent-workspace-linux/{default.nix,sources.nix,update.sh}` | Same leaves in `lib/ext/agent-workspace-linux/` | Constructor exact; destination 0.6.4 versus source 0.6.1; updater differs only in relocation paths, `100755` retained. |
| `pkgs/ext/bladebro/{default.nix,sources.nix,update.sh}`              | Same leaves in `lib/ext/bladebro/`              | Constructor exact; destination 4.6.9 versus source 4.6.5; updater differs only in relocation paths, `100755` retained. |
| `pkgs/ext/tuicr/{default.nix,sources.nix,update.sh}`                 | Same leaves in `lib/ext/tuicr/`                 | Constructor and source record exact; updater only relocation paths, `100755` retained.                                 |
| `pkgs/ext/awl/default.nix`                                           | `pkgs/ext/z-push/awl.nix`                       | Identical blob, consumer-local dependency.                                                                             |

These are **ten one-to-one aliases**, fully enumerated in JSON: **five equal /
five intentionally different**. If each source/candidate alias pair is collapsed
once, the denominator becomes **1,634 units**: **989 equal, 60 different common,
517 source-only, 68 candidate-only**; common comparison denominator **1,049**.
This is an additional view, not a replacement for the raw path counts.

Two non-bijective relations are **not** folded into that alias arithmetic:

- Source `pkgs/ext/awl/sources.nix` is the identical AWL record inside
  already-common `pkgs/ext/z-push/sources.nix`. Destination Z-Push builds
  `./awl.nix` and exposes `passthru.awl`; `lib/services/activesync/default.nix`
  uses `cfg.package.awl`, retaining selected-package override correctness.
  Z-Push 2.7.6 / AWL 0.65 remain unchanged.
- Source `lib/sway.nix` settings are covered by `lib/wm.nix` plus
  `lib/desktop-base.nix`, imported by `lib/profiles/desktop-core.nix`. Preserve
  destination GPU/session/Niri additions rather than add a redundant
  auto-imported module.

## Common library dispositions

All **22** raw common differences are accounted:

| Group                       | Count | Exact paths / decision                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------- | ----: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Destination fixes/additions |     3 | `lib/boot.nix`: early `rtc_cmos`; `lib/locale.nix`: GeoClue and conditional timezone recovery; `lib/nix.nix`: Numtide cache.                                                                                                                                                                                                                                                      |
| Destination pins            |     4 | `lib/ext/{pi,prism-llama-cpp,tailscale,vscode}/sources.nix`. Preserve newer destination pins; constructors/updaters match. Pi has the same 24 units; differences include ordering, updated pins and their dependency records, not missing extensions.                                                                                                                             |
| Repository policy           |     6 | `lib/hardware.nix`, `lib/installer/config/default.nix`, `lib/network.nix`, `lib/sudo.nix`, `lib/systemd.nix`, `lib/services/nix-builder-gc-coordination/default.nix`. Keep firmware/workstation policy, live-image/user/disk targets, resolver policy, sudo timeout, suspend throttling, and builder **16 jobs / inherited 0 cores / 16 connections**, not source **1 / 12 / 8**. |
| Repository check injection  |     1 | `lib/flake/repo-checks.nix`: Pvl identity assertions and owned root-check membership, not private source promotions. Generic Nixbot package tests remain present; source's extra root promotion is composition, not a missing implementation.                                                                                                                                     |
| Qualification policy        |     4 | `lib/flake/rust/qualification/{README.md,cargo-order-check.nix,recipe-vm.nix}`, `lib/flake/rust/tests/test_layout.py`; see retained lane below.                                                                                                                                                                                                                                   |
| Native repair               |     2 | `lib/services/abird-host-manager/build-controller.nix`, `lib/tests/build-executor-control.nix`; explicit correctness adaptation below.                                                                                                                                                                                                                                            |
| AWL improvement             |     1 | `lib/services/activesync/default.nix`, as above.                                                                                                                                                                                                                                                                                                                                  |
| Test registry               |     1 | `lib/tests/default.nix`: all source AI/lint/fleet registrations retained; Numtide assertions preserved; synthetic-provider OpenDesign check additionally registered on Linux.                                                                                                                                                                                                     |

The remaining generic Rust cold-source/filter changes and fixtures, AI
implementation/tests, fleet module imports/executor/capture files and other
imported generic library tests match S. Hash parity proves transferred content,
not installed behavior.

## Optional Cargo qualification

The stock-only retirement portion of source
`230f38141d957c8808bce4f0d7661fc950542617` and corresponding `7ace9dcaf...`
policy prose are intentionally not adopted. Destination's explicit
qualification-only #16691 exception remains; ordinary production Cargo stays
stock. All eleven retained paths match D:

```text
lib/flake/rust/qualification/README.md
lib/flake/rust/qualification/cargo-dep-info-order-16691.patch
lib/flake/rust/qualification/cargo-order-check.nix
lib/flake/rust/qualification/patched-cargo.nix
lib/flake/rust/qualification/recipe-vm.nix
lib/flake/rust/tests/test_layout.py
scripts/qualification/rust/README.md
scripts/qualification/rust/abird/recipes.nix
scripts/qualification/rust/pvl/manager-patched-vm.nix
scripts/qualification/rust/pvl/manager-recipes.nix
scripts/qualification/rust/pvl/manager-vm.nix
```

**Six** are in this lib/pkgs manifest (four different, two candidate-only);
**five scripts are outside its denominator**. Retained support/callers are
coherent with `.agents/docs/design-patterns/rust-foundation.md`. The independent
generic lazy-source assertion from the same source change is adapted into
`lib/flake/tests/pvl/child-flake-parity.nix`; retaining policy does not discard
that assertion. No claim is made that stock Cargo acquired the ordering fix or
that patched qualification proves stock determinism.

## AI library and application fixtures

All **19** `lib/services/ai/` files are byte/type/mode-identical to S.
Pure/typed inference, checked consumer binding, credential-reference/file
primitives, menus and generic tests are present without migrating Pvl host
policy.

The **ten** source-only helper files are explicit **application-fixture
decisions**, not private products and not required dependencies of the adopted
shared AI tree:

| Unit — each has `default.nix` and `sources.nix` | Source consumer / retained boundary                                                                                 |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `lib/ext/dotenv/`                               | AnythingLLM saved-settings harness, npm 16.4.5.                                                                     |
| `lib/ext/hermes/`                               | Source Hermes adapter harness at its pinned revision; no destination Hermes adapter adopted.                        |
| `lib/ext/librechat/`                            | Source LibreChat 0.8.7 adapter fixture; destination image/multi-device behavior has its own qualification boundary. |
| `lib/ext/open-webui/`                           | Source 0.9.6 adapter/host guard; not destination's 0.10.2 qualification.                                            |
| `lib/ext/openclaw/`                             | Source native-client adapter fixture; no corresponding destination adapter adopted.                                 |

JSON names each exact source caller and pin/constructor role. Mixed synthetic
protocol tests under source `lib/flake/tests/abird/` are classified by their
concrete adapter/host/version imports, **not merely the directory name**. They
are not claimed equivalent to destination app qualification. Shared AI tests and
the generic Graphiti/OpenDesign package regressions are present independently.

## Child-flake composition

Exactly **13** common wrappers differ only in source's
`rustWorkspaceDeps = false` injection; their declared inputs match. Retain
destination composition/admission rather than importing Abird's 24-member
default-off product policy:

```text
pkgs/cloudflare-apps/flake.nix
pkgs/cloudflare-apps/llmug-hello/flake.nix
pkgs/examples/hello-go/flake.nix
pkgs/examples/hello-node/flake.nix
pkgs/examples/hello-python/flake.nix
pkgs/examples/hello-rust-isolated/flake.nix
pkgs/examples/hello-rust/flake.nix
pkgs/examples/hello-web-static/flake.nix
pkgs/support/nats-http-bridge/flake.nix
pkgs/tools/abird-host-agent/flake.nix
pkgs/tools/abird-host-manager/flake.nix
pkgs/tools/nats-wrecking-ball/flake.nix
pkgs/tools/nixbot/flake.nix
```

Evidence: source `c50d5c579`, source
`lib/flake/tests/abird/rust-fabric-policy.nix` / `child-flake-parity.nix`,
destination `lib/flake/tests/pvl/child-flake-parity.nix`, and shared
`lib/flake/stack/package.nix`. This is not a blanket flake/lockfile exclusion.

## Shared package adaptations

The **33** raw common package differences are exhaustive: **13** child wrappers,
**4** inventory/encrypted-input docs/manifest paths, **2** Z-Push files, **3**
Graphiti files, **9** existing manager repair files and **2** reviewed Nixbot
hardening files.

- **OpenDesign:** `pkgs/ext/opendesign/managed-byok-provider.patch` is
  **source-exact** (`c1d95fb3c587223313dc735a01e22a6f0b1c0e79`). It seeds only
  absent browser config, preserves saved/invalid/unreadable state and tolerates
  failed persistence. Candidate-only `tests/default.nix` supplies a synthetic
  non-null provider so the package suite cannot silently skip; `tests/README.md`
  documents it. `lib/tests/default.nix` binds the check on Linux. No source host
  proxy/override is copied.
- **Graphiti:** `app/main.py` adopts independent embedder key/base while
  preserving legacy chat binding **only when both new variables are absent**.
  Partial/blank pairs fail before constructing either client.
  `tests/test_core_contract.py` retains the real-client independent binding
  regression and adds legacy/default/refusal cases. `tests/README.md` plus new
  `tests/run.py` specify the pinned, two-process **manual** gate. The normal
  package/root checks do not run real-core tests; no missing Graphiti Nix
  factory is implied.
- `pkgs/README.md`, `pkgs/manifest.nix` retain repository package
  membership/export and selected usage examples; the two Cloudflare app READMEs
  retain encrypted-input locations. Shared package constructors/check mechanics
  remain represented separately. These four files are not blanket implementation
  exceptions.

### Current destination Kilo removal

`pkgs/tools/kilo-cli/default.nix` is now **source-only**, classified
`policy-current-destination-removal`. Destination commit
`47bb09380e10dcf25ea7c50df16cf375a5d7b053` intentionally deletes the prebuilt
wrapper and its `pkgs/manifest.nix` registration. The current policy note,
`.agents/docs/notes/tooling/kilo-removal-2026-11.md`, records that Pi is the
fleet's coding tool; `505c727e2323ce888ad2d4201ce5352c9c4516cb` also removes the
VS Code extension outside this inventory. The user's current main removal wins:
restoring Kilo for equality would undo an explicit destination decision, not
close a generic transfer gap. This is not an intrinsic-privacy exclusion.

The wrapper's source and original-baseline blob remains
`9f225995f2db412f451d11f1ac17738c89799c83`; its current target is absent.
`pkgs/manifest.nix` remains `policy-package-membership` and different from S;
its current blob is `37d8eff8b9dafc65cabb36d0608d3e0528df3bd8`, while its
original-baseline blob remains `a85616f520fd5f45fa2273c8d7929def94caf2e4`. Both
current dispositions follow the integration-base bytes, without rewriting
historical D metadata or changing any other path's disposition.

### Native consumer hardening

Relative to S, retain **nine existing manager-file adaptations**, **one new
regression**, and **two Nix adaptations**. Let **A** be
`pkgs/tools/abird-host-manager/src/fleet/build_backend/agent/`:

| Exact file                                                      | Adaptation                                                                                                             |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `A/acquisition.rs`                                              | Preflight before acquisition routes, roots and import claim.                                                           |
| `A/acquisition/native.rs`                                       | Shared immutable ABI3/exact-Nix loader; sanitized metadata-only private preflight with no acquisition/store operation. |
| `A/acquisition/native/child.rs`                                 | Reuse bounded duplex helper without an exclusion descriptor for preflight; acquisition retains its descriptor.         |
| `A/controller.rs`                                               | Qualify installed actions before recording/Submit and reconnect before retained-state effects.                         |
| `A/commands.rs`                                                 | Qualify explicit low-level Submit before parent creation.                                                              |
| `A/entry.rs`                                                    | Fixed arity-checked, redacted private dispatch.                                                                        |
| `A/controller/tests.rs`                                         | Preserve unclaimed and pending manifests on rejected preflight; explicit partial-root recovery fixture.                |
| `A/capture.rs`                                                  | Test-only `std::slice::from_ref` Clippy correction.                                                                    |
| `pkgs/tools/abird-host-manager/tests/fleet_strategy.rs`         | Early incompatible-consumer rejection expectations; no-effects assertions retained.                                    |
| `pkgs/tools/abird-host-manager/tests/fleet_native_admission.rs` | New package-layout/ABI/canonical-alias/foreign-program no-effects regression.                                          |
| `lib/services/abird-host-manager/build-controller.nix`          | Enabled consuming bootstraps require ABI3 and exact selected Nix 2.34.9; disabled/routing-only exemptions remain.      |
| `lib/tests/build-executor-control.nix`                          | Compatible and missing/foreign/wrong-version/disabled/routing-only cases.                                              |

The latest independent review closes the targeted P2 for these same hashes. Its
twelve-file manifest is
`bb3fb733e87f99b40c807b4e6a64648006922212c73f653e50ae5c73ab152f69` (SHA-256 of
sorted `SHA256(file) + "  " + full-path + "\n"` records). This parity pass
checks identity against that receipt; it does **not** rerun or inherit
executable test claims. The [neutral interface guide](owned-build-interface.md)
and actual code retain default-off, exact ABI/Nix, authority, uncertainty and
settlement boundaries.

### Frontend hardening and review closure

**Both frontend P2 findings are closed** at the final independently reviewed
blobs, rehashed here from the actual filesystem:

| Path                                       | Final reviewed Git blob                    |
| ------------------------------------------ | ------------------------------------------ |
| `pkgs/tools/nixbot/nixbot.sh`              | `08a0890442dbdefe37703b5aba7dadef6307d389` |
| `pkgs/tools/nixbot/tests/test_strategy.py` | `92c498fc63be9ae90a27340b68172c362fa23f57` |

The shell retains early installed-manager delegation/rejection before ordinary
Nix bootstrap and the constant-scoped SC2034 annotation. Shared selector
normalization is now builtin-only, preserving token bytes, stable deduplication,
ordering and newline behavior without fatal pre-bootstrap `awk`, `tr` or `paste`
dependencies. Builtin help removes the `cat` dependency without changing output
bytes. Original hydrated argv, ordinary auto/Nix re-exec, thin CI and
managed-override intent checks remain; no second strategy parser, local native
profile gate or agent Nix fallback is introduced.

`tests/test_strategy.py` preserves all seven source strategy tests and adds the
fourteen-method real-entry/helper recorder class. The separate independent
verification records **14 focused tests**, the original **12-case** and expanded
**182-case** sparse-PATH matrices, **5,232 byte-level normalization
comparisons**, and byte-identical **14,664-byte** help with `cat` unavailable.
Those results explain the bounded review closure; **this parity refresh did not
rerun those tests or certify installed/VM behavior**. The repair does not claim
the entire script is external-tool-free: inherited initialization, ordinary
bootstrap and encoded-request prerequisites remain.

The source-exact completion file `pkgs/tools/nixbot/nixbot.bash` is separately
included in the equal set; the two Bash files are not both drift exceptions. The
JSON classification is now `local-hardening-frontend` for the two adapted paths,
with no pending snapshot entries. Main's independent final formatting/lint and
broader runtime qualification remain separate. No implementation changes were
made by this parity audit.

## Identity and product boundaries

No directory-wide allowlist is exported. Every member has its own row, hash,
reason and evidence.

- Source `lib/flake/tests/abird/` has **36** absent files: actual
  host/stack/fabric/cache/product composition, default-off policy and
  adapter-version harnesses. `lib/services/kanidm/tests/abird/gap3.nix` imports
  real Gap3 OAuth configuration;
  `lib/tests/abird/nix-builder-gc-coordination.nix` asserts actual source
  capacities. Their generic service/library mechanics remain present.
- Retain **11** Pvl flake-test files plus its GC-default test. Four Pvl Rust
  files provide additional real-pinned constructor integration coverage; they
  are explicitly classified as retained extra coverage rather than intrinsically
  private. Pvl child parity retains the newly adapted lazy-source assertion. The
  secret-named identity check is hashed only; no referenced secret values or
  test execution is involved.
- Source
  `pkgs/tools/nixbot/tests/abird/{TEST-DISPOSITION.md,__init__.py,test_nixbot.py}`
  is the private migration-ledger assertion/discovery unit, not the generic
  Nixbot tests. The generic discovery/fixtures are present.
- **244 private product files** remain absent, enumerated across
  `pkgs/apps/abird-app/`, `pkgs/srv/abird-agent/`,
  `pkgs/support/abird-protocol/`, `pkgs/web/abird-web/`. Product
  constructors/imports establish the coherent boundary; shared
  `pkgs/tools/abird-host-*` is not excluded by name.
- **10 Codex App Server files** remain coupled to
  `pkgs/srv/abird-agent/codex-protocol-policy.json`, controller patches and
  contract checks. This is different from the retained destination
  `pkgs/tools/codex-wrapper/` CLI wrapper.
- **171 previously excluded bot/lab/hosting/service files** retain their exact
  package-membership decisions. **35 technically shareable files** are
  separately marked `prior-skip-shareable`: SQLite queue **9**, PostgreSQL queue
  **8**, EDI AST example **7**, `srv/llm` **6**, `srv/search` **5**. Their
  omission is not intrinsic privacy. Exact prior decisions:
  `.agents/docs/notes/tooling/abird-post-1fd-parity-2026-09.md` (“Complete
  source-only inventory”) and `abird-post-278a2cba-audit-2026-09.md`
  (“Out-of-scope observations”).
- The two
  `pkgs/support/nats-streams/{chat-intelligence.nix,specs/chat-intelligence.nix}`
  files are source Gap3 registrations; the generic factory matches.
  `pkgs/srv/README.md` describes excluded product membership.
- Candidate-only device/desktop/profile/audio/Wi-Fi/MCP/editor/Codex support is
  preserved path by path. `gimp-mcp`'s patch and `mcpvault`'s vendored lock
  correctly keep those units repository-managed under `pkgs/ext/`.

## Auxiliary surfaces — not root-file parity

Outside the 1,644-path denominator, targeted rechecks confirm source-exact
`scripts/fmt.sh`, `scripts/lint.sh`, `.githooks/pre-push` and `.gitattributes`:
repository `.` formatting, bounded/root lint and Git isolation, additional
`GIT_EXEC_PATH` clearing, and direct/recursive encrypted-file `-text -diff`
protection. Four Terraform variable files retain the selective adaptation:
`tf/modules/cloudflare/variables.tf` and
`tf/cloudflare-{apps,dns,platform}/variables.tf` use effective
`try(predicate, false)` required-field/uniqueness checks, preserving encrypted
map routes and stronger destination fields. `access.tf` remains unchanged under
the explicit prior `71af6cdd` skip. Assets-only allowance is validator-level,
not proof that unchanged Worker resources accept omitted module attributes. No
tfvars, backend/state or secret contents were inspected. This paragraph is
**not** a whole-root-file or full Terraform qualification claim.

## Recheck procedure and limits

Recompute the complete source tree and actual candidate files as described
above, then compare each row, counts, symlink literals and canonical
fingerprints. At minimum, JSON self-integrity is reproducible without evaluating
repository code:

```python
import hashlib, json
from pathlib import Path

report = json.loads(Path(
    ".agents/docs/notes/tooling/abird-port-2026-11/parity.json"
).read_text())
rows = report["rows"]
assert len(rows) == len({row["path"] for row in rows}) == 1644
assert [row["path"] for row in rows] == sorted(row["path"] for row in rows)
assert all(row["classification"] and row["reason"] and row["evidence"] for row in rows)

def digest(value):
    return hashlib.sha256(json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()).hexdigest()

assert digest([{k: row[k] for k in ("path", "source", "target")} for row in rows]) == report["manifest_sha256"]
assert digest(rows) == report["classified_rows_sha256"]
```

That snippet checks report integrity only. This final refresh separately
rehashed **all candidate files** and verified the complete source/candidate
union, not just those JSON digests. Any subsequent filesystem or
integration-base change requires another rehash and regenerated
rows/fingerprints; a matching HEAD is insufficient. There are **zero provisional
paths** in this snapshot.

This audit ran metadata/content comparisons and report formatting, **no builds,
application tests, Nix evaluations, Terraform operations or live probes**. It
does not assert exhaustive semantic review of every imported executor line.
Native namespace/cgroup/Landlock/daemon and installed workflow qualification,
full OpenDesign image checks, Graphiti's manual real-core gate and canonical
integration results belong to separate verification. No source edits, staging,
commits, pushes or credential reads were performed. Final report artifacts only.
