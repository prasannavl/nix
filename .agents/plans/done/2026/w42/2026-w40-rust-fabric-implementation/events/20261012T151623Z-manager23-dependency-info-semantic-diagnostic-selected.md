---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-12T15:16:23Z
tags: [area:rust, qualification, diagnostic]
---

# New bounded dependency-info diagnostic selected

The human's current validation preapproval authorizes continued reversible
diagnosis. Main selects a new prospective unit,
`manager23-dependency-info-semantic-v1`, following the successful closed V6
two-archive comparison. This is a distinct semantic read scope, not an extension
of the earlier hash-only scope or a replay/refund of V3/V6. No semantic Source
or native archive execution has been issued at this selection cutoff.

The closed V6 result established equal member sets (80 entries each), 11
metadata-record differences and 15 regular-payload differences, including seven
dependency-info files and six executable/library files. Metadata includes size;
its 11 differences do not establish timestamps or permission differences.

## Finite surface and interpretation

- Exactly the same two original plan/log-bound head archives, with the sealed V6
  compressed hashes bound before accepting a result. Preserve the existing
  physical ancestor/root/held/path full-stat9, ownership, exact previous-link,
  immutable library and complete compressed/tar EOF checks. Read each archive
  once in this new unit; hash every regular body. Do not read parent archives,
  extract, follow payload references, enumerate private roots or emit raw names,
  paths, tokens, environment names/values or payloads.
- Add fixed field counts for kind, mode, uid, gid, mtime, uname, gname, size,
  link, atime and ctime. Split the original extra metadata tuple explicitly;
  retain original comparison and opaque map hashes.
- Semantically decode only already policy-admitted safe regular `.d` bodies, at
  most 1 MiB each. Working decoded RAM at most 2 MiB per entry, retained
  descriptors at most 8 MiB, and aggregate retained material at most 64 MiB. No
  ELF parsing or executable buffering belongs to this unit.
- Parse supported Rust Makefile dependency targets/prerequisites and env-dep
  records with explicit escaping/continuation behavior. Emit fixed counts and
  opaque raw ordered/multiset signatures. Unsupported syntax, ambiguity,
  duplicate forms and bounds must be explicit incomplete coverage or refusal;
  never certify equality by omitting unparsed material.
- An optional diagnostic candidate signature may replace only a complete
  canonical absolute-path component
  `nix-<decimal PID>-<decimal uint32 counter>`. Both paired `.d` files must
  contain one unique byte-identical absolute parent. Preserve parent and all
  suffix/token bytes. Missing, multiple, unequal or unrecognized parents cannot
  receive normalized equality. Emit only an opaque parent hash and fixed
  coverage counts, with the literal interpretation
  `CANDIDATE_COMPONENT_SAME_PARENT_ONLY_NOT_PROVED_RUNTIME_ROOT` and
  runtimeRootProven false. This is a candidate comparison, not causal
  attribution or a claim that the observed component was the actual runtime
  build root. Nix 2.34.8's Source selects a configurable build-dir parent;
  neither `/tmp` nor the historical `nix-build-<name>-0` spelling is assumed.

## Admission and completion gates

Source25 wall, CPU15 aggregate, AS512 MiB, one CPU, read128 MiB aggregate,
file16 MiB, program32 KiB and preserved64 MiB remain unchanged. Use the
unchanged genuine mode0 monitor and the reviewed direct original Python ELF
child. Retain the explicit trusted-parent startup boundary and
fullProcessReadAssurance false; do not exempt child libraries or relax
exec/API/read policy. New exclusive output names and exact
Source/controller/bootstrap/caller/read-surface pins are required. No old
command is rearmed.

Main and an independent peer must review the complete new Source, real caller,
read surface and meaningful controls before a once-only native unit. Controls
must cover field attribution, escaping/continuations, complete syntax coverage,
same-parent candidate-ID changes, negative parent/suffix/env-value cases,
numeric and memory limits, protected references and unchanged payload SHA/full
EOF behavior. Exact program-size and resource bounds are admission gates.

Cargo, rustc, Crane, compiler flags, features, recipes, hooks, wrappers and
production implementation remain unchanged. The forced warm build is still
failed and all G1-G11 gates remain open. This diagnostic may locate a correction
but cannot itself qualify warm reuse, integration or adoption.

Sources for the prospective interpretation are the exact tagged Nix 2.34.8
`derivation-builder.cc` and `file-system.cc` reviewed from the upstream primary
repository. Runtime build-directory/config values remain unobserved.
