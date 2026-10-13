---
id: 20261013T125426Z-independent-final-candidate-qualification-review
type: review
plan: 2026-w40-rust-fabric-implementation
reviewer: agent:m22-review
verdict: scoped-accept
---

# Independent final candidate qualification review

The independent reviewer accepts the selected regular-Cargo native manager
reuse, candidate mirror parity, actual Abird24 constructor/context evaluation
and selected-manager timing evidence. Main executed the cases; this reviewer
read and authenticated their actual public evidence and reviewed the relevant
Source, without executing builds, tests or candidate entrypoints. This is
candidate qualification, not production integration, publication or adoption
approval.

## Actual runtime evidence

- The preserved Abird report is 31,729 bytes, SHA256
  `c4fabb753382b2732f98848aa8af846ca0ccea16493da28c02aebe37859c708b`. Both
  copies of its structured result in the complete ordinary build log match it
  exactly. All six required cases passed version, command, retained-log and
  compilation-frontier checks. Each independent guest initially lacked 11 tested
  outputs. Required six-case acceptance is independently derived; the original
  report has no `requiredReuseChecks` field and remains outer FAIL because its
  later legacy comparison failed before compilation.
- Baseline, cache hit and binary-cache restoration have identical NAR hashes,
  sizes and references. Cache hit/restoration compiled zero crates; restoration
  disabled build jobs. Both warm compilations logged two workspace and zero
  external compilations. The changed probe appeared in both warm and independent
  fresh packages. Native baseline recipes match the accepted Abird mirrors.
- The separately selected legacy-only report is 7,095 bytes, SHA256
  `a6eda9bf1db54e84b907408e1b44d362d72692909b2b092b7088efb20a5b3aba`. It matches
  the registered output and the complete normal log. Only the legacy case ran,
  after 13 tested-output absence checks. Version and changed probe passed; the
  retained actual log independently confirms 214 compilation messages, 208
  external, with agent and manager workspace names.
- The final common-driver smoke is 13,560 bytes, SHA256
  `dc2e61b258276e6ed2ce6487bc041e656190326d6052082dc08dc075e88c813a`. The
  registered report and all six retained logs were authenticated. All six cases
  passed with zero Cargo compilations; this verifies the shell-smoke lane, not
  Rust product reuse by itself.

Actual result/Source authentication held full nine-field file and physical
ancestor identities before and after reads. The final legacy/smoke pass held 21
files and 16 ancestors, requesting 282,453 bytes. No private archives or secret
payloads were read. Historical spent manager/reader units were not reopened.

## Mirrors and context boundaries

Earlier independent provenance reviews remain accepted: Pvl validation revision
`e360fc893a7f8c2ab4129ef4b12aa89de029c211` has 295 declared files and 275
emitted files; Abird revision `bf72d3e59b2ff0b6d2d4c12b16aee82009d9ecdd` has 457
declared files and 278 emitted files. Original inventories/blob identities and
emitted hashes/modes were authenticated. Both `--check` results match. Original,
standalone, explicit-base composed and actual in-repository forwarding routes
have equal package/build/base/vendor/tool/fleet/check identities, joined to
executed native recipes. Recompiling identical recipes is unnecessary for this
mirror claim. These revisions remain validation-only candidates.

The actual Abird report constructs all 24 member bases with one full-lock vendor
and passes 18 policy plus 18 toolchain assertions. Platform evaluation
constructs 20 native contexts and records four declines: controller
`RUST_TEST_THREADS`, two WASM adapters and parent-owned Tauri
hooks/assets/strictDeps. Cross and partial-WASM admission reject. Tauri is
authenticated argument capture plus existing policy evidence, not a constructed
product. Neither 24-product native execution nor ARM runtime is established.

## Source and measured cost

The reviewed correction adds actual legacy dependency producers to forbidden
seed outputs and selects their declared source/dummy-source inputs. It does not
seed compiled project artifacts. Comparison-only creates one guest and executes
only legacy; successful required cases are not replayed. The common driver,
manager and smoke resource defaults are 16 CPUs and 16 GiB under the latest
human instruction. Driver OS inputs may use cached Pvl Nixpkgs; target Abird
recipes preserve their exact original Nixpkgs/Crane/toolchain inputs.

Legacy elapsed time was 187.7504961490631 seconds; changed warm was
159.33626136393286 seconds. Their observed same-changed-source difference is
28.414234785130247 seconds, or 15.134039785743616 percent. Unchanged warm was
112.94852961599827 seconds. These are single selected-manager workflows with
shared prerequisites, uncontrolled host load/OS caches and runtime/log checks
included. They do not establish full-workspace cold cost or universal payback.
Member-head/package NAR sizes exclude parent-cache storage costs.

The retained qualification Source manifest has 31 files, 265,236 payload bytes,
SHA256 `1fb4cf8a60a313c9a897b03017a3ad26c09b15f9385dbcfdfb0f45dcdedbf2a7`. Every
listed copy matches current original Source bytes and its declared hash.
Regeneration instructions preserve immutable candidates and distinguish target
inputs from driver infrastructure. Current routing/design/state additions
preserve the original outer FAIL, optional byte-determinism FAIL, unsupported
contexts and integration/adoption boundary. Final retention and documentation
synchronization are Main's remaining closeout work.

Independent-build byte determinism remains optional FAIL. No fingerprints,
producer outputs, compiler flags or compatibility guards were normalized to hide
it. No production default, repository refs/indexes, staging, commits, deployment
or adoption were authorized by this review.
