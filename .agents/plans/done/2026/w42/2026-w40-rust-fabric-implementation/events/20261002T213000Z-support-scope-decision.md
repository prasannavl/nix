---
id: 20261002T213000Z-support-scope-decision
at: 2026-10-02T21:30:00Z
actor: agent:rust-fabric-main
type: decision.recorded
subject: milestone:source-support-admission
supersedes: implementation:inferred-computed-resource-authority
tags:
  - area:rust
  - authority:code-only
  - concern:maintenance
---

# Declare source ownership; do not infer arbitrary Nix resource effects

Fresh independent review reproduced resources lost through local-reader calls,
builtin aliases and constant host filenames despite the previous bounded
scanner. The growing ~1,058-line structural parser/taint engine was not a sound
general resource-closure authority. More syntax exceptions would worsen
correctness and maintenance; the human explicitly requested simple, scalable
design and fixes.

Replace that authority with a small revision-owned Nix source declaration and
bounded actual export validation. The declaration selects cohesive
helper/service ownership areas, not packages, compiler capabilities, manifest
routing or JSON registries. Selected member directories still come exclusively
from the pinned Cargo planner; original definitions and Cargo/root support bytes
remain pinned.

`lib/flake/rust-mirror-sources.nix` owns the support scope: `lib/flake` and
`lib/services`, excluding the separately owned `lib/flake/tests` subtree. Tests
contain deliberate unsafe/symlink fixtures and are not runtime support sources.
Exclusions apply only to declared support enumeration, never to selected member
trees. No selected unsafe mode/content guard is relaxed. This is an intentional
small ownership superset, not copying the whole repository or all of `lib/`.

Python owns Git-object extraction, metadata preflight, declaration/schema
checks, manifest-only planning, inventories and atomic output ownership. Nix
owns parsing its declaration and evaluating actual native exports.
Completed-mirror validation is offline/restricted/no-IFD with exact cached
inputs and no lock writes; missing cache fails rather than fetching. Do not
grant it the full planning snapshot.

Assurance: authoritative owner declaration plus validation of exercised package,
check, library/source, shell/formatter and app exports. Dormant methods,
alternate configurations/platforms, caller-provided sources and arbitrary
build-time effects are not certified. Restricted Nix evaluation is not a
universal sandbox for arbitrary malicious code. Keep these limits explicit;
provenance remains freshness only and cannot admit compiler artifacts.

Reserved output provenance paths must reject pinned-source collisions rather
than overwrite original bytes. Full-workspace planning should copy manifest
bytes and metadata-derived structure, not unrelated payload blobs. This is a
code-only prototype interface change; no master/child/root adoption or
publication follows.
