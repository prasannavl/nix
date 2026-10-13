---
id: 20261002T224000Z-fresh-review-validated
at: 2026-10-02T22:40:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: milestone:fresh-retained-worktree-review
tags:
  - area:rust
  - authority:code-only
  - evidence:evaluation
  - state:uncommitted
---

# Fresh review, concrete repairs and simpler source authority

Human requested a fresh bugs/regressions/correctness/design review and concrete
fixes. Four independent read-only lanes reproduced defects, then owned disjoint
repairs. MAIN integrated source guards and private writer/environment
observation, validated live code and coordinated a fifth independent
source-authority review. Assignments: `20261002T210240Z-fresh-review-claims.md`;
architecture decision: `20261002T213000Z-support-scope-decision.md`.

## Findings repaired

1. Exported explicit bases bypassed bound source/default dependency
   normalization. Export calls now retain that context and source closure even
   when an intrinsic dependency is null; conflicting handles compare all three
   output identity fields.
2. Automatic bases used the factory compiler/library instead of recipe-selected
   consumer context. Every contextual ancestor now uses actual effective
   context; explicit factory queries and stale-base rejection retain their
   semantics.
3. Mirror shell compiler reselection and lost owned development dependencies.
   Reuse actual selected tools, writer and projected environment; retain owned
   inputs. Strip inherited shell hooks because `mkShell.inputsFrom` concatenates
   them even when its own hook is empty. No entering-shell source rewrites.
4. Final output checks preceded registered `postInstallHooks`. Expanded
   packaging now checks known artifact paths in a helper-owned final phase after
   install and fixup; six registered-hook positive controls reject.
5. Expanded local operation descriptors missed projected native env and expanded
   literal values. They reuse the validated projector environment with
   literal-safe serialization, including quotes, dollars, command text and
   newlines. Old/null branches retain earlier serialization and derivation
   identities.
6. Source binding checked top-level src but not active merged/supplied source.
   Rust, Crane, workspace and Trunk adapters check effective sources too;
   inactive overrides remain lazy and unbound/null defaults unchanged.
7. Unsupported overlapping root members could probe omitted trees. One shared
   root-topology preflight rejects before member values/manifests/config scans.
8. Computed resource bypasses remained in the expanding Nix scanner. Removed the
   inferred structural-resource authority entirely, replacing it with a pinned
   ownership declaration and mandatory bounded actual native-export validation.
9. Planning read entire unrelated member payloads. Metadata-mode preflight and
   metadata-derived directory structure plus manifest blobs replace those reads.
10. Reserved provenance/source collisions and secret-output ordering. Pinned
    root stamp collisions reject, generated-root collisions cannot overwrite
    retained sources, and both lexical absolute secret-tree arguments reject
    before Git.

## Simplicity and assurance

Python generator is roughly 497 lines instead of ~1,058; no structural Nix
parser, call/alias taint table or helper-name exemptions remain. Small Nix
validator uses exact existing cache objects; no
fetchTree/getFlake/network-capable cache filling. Cold cache fails clearly.
Revision-owned support areas are `lib/flake` and `lib/services`; separately
owned `lib/flake/tests` is excluded from support only, never selected members.
Synthetic revision contains all six deliberate symlink objects, with tests
proving they are not read/materialized through that exclusion. Selected unsafe
modes still reject. Pristine Cargo/member/wrapper bytes retained.

Owner declaration plus exercised native exports is not arbitrary-Nix closure or
filesystem sandbox certification. Dormant branches/platforms/caller
configurations, explicit external sources, build-time reads and intrinsic
Nix-store access remain limits. Artifact/provenance metadata remains
freshness/construction evidence only.

## Executed validation

No Cargo/native builds/captures, network/provider fetches, root/host
applications, secret-key reads, user staging/commits/refs/publication or master
changes.

- **40 generator / 185 complete support / 56 spike tests** pass.
- **13** child input refs still match unchanged root lock originals.
- Pure **118 closure / 103 base / 43 composition / 44 projector / 73 native / 29
  export** assertions; existing pure toolchain suite passes.
- Four cached contexts, bare and overlaid x86/ARM Linux, each pass **131 scope /
  60 in-tree mirror / 60 actual generated-entry mirror / 10 adoption**
  assertions.
- Four cached contexts each also pass **104 real base / 36 composition / 73
  native**; baseline default/null and zero-context explicit/automatic identities
  match. Ten private observer/identity assertions per context also pass.
- Actual restricted offline no-IFD native CLI **write**, then **check** passes
  with six excluded negative symlink objects present in the selected synthetic
  revision.
- Generated final-phase hook/environment shell executed without Cargo: clean
  output accepted, all six install/fixup forbidden-path controls rejected,
  literal env roundtrips. This is not real Crane inheritance/build evidence.
- Independent source cross-review `01a0fe9b-4c7c-74c4-80f2-1c95575b9a1f`: no
  code P1/P2; stale boundary documentation finding corrected, including store
  limitations. It independently ran isolated units, actual metadata-only
  planning and restricted host/planning-sibling deny/allowed-resource probes,
  not native package builds.

Nix/Markdown formatting and whitespace checks pass. Most-specific durable notes,
index, canonical plan and materialized work view updated; raw events retained.
Successful owned `tmp/fresh-review-*` fixtures/evaluators/reports cleaned;
unrelated `tmp/helper-consolidation` untouched. Larger plan remains
active/queued, not archived.

Pvl master remains `5ae0baf0`; Abird remains `1f4057ee`; staged diff empty. All
post-port code remains uncommitted in retained worktree. Exact producer
fidelity, real archive inheritance/reuse, native/platform/cost qualification,
root adoption, integration and publication still require separate
authority/evidence.
