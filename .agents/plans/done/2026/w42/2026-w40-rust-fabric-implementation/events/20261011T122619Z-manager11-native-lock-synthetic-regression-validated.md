# Manager 11 native lock Source regression validated

- Type: validation
- Time: 2026-10-11T12:26:19Z
- Coordinator and executor: ROOT
- Source author and recorder: /root/cargo_cause
- Scope: bounded Source-only synthetic regression; current qualification remains
  pending

ROOT reported the actual once execution `exec95700` closed with exit 0 after
reading the complete candidate and exact caller. The direct tool transcript
reported `SYNTHETIC_NATIVE_LOCK_REGRESSION_PASS`, count 13, Source bytes
11,862,720. This record preserves ROOT's actual transcript observation; there is
no saved stdout artifact or inferred runtime receipt. No rerun is authorized by
this validation record.

The reviewed Source is
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/tmp/manager11-warm-lock-source-20261011/regression.py.txt`,
11,946 bytes, SHA-256
`c4a9e25285f9891ac45bbda1ff78100f0a34c25cb2dd6b46f9393338d7898b02`. The exact
caller is the adjacent `ROOT-regression-command.sh.txt`, 1,381 bytes, SHA-256
`4f0e0fe69641ead1f46b9a91ca09d5d149ae7bc9849d9c892a02a2179dffc081`. It preserves
the existing held-Source bootstrap and Source25 wall, CPU15, 512 MiB address
space, 16 MiB file, one-CPU affinity, 128 MiB total read budget, and empty
environment constraints. The fixture has an internal 20-second cap.

The candidate existing `semcheck.py` replacement is the adjacent
`semcheck-v3.py.txt`, 30,470 bytes, SHA-256
`4fa8c17cb50fc6f77137e41a6879095cb9723ea03799c57973d3f880c3553948`. Its
correction derives only the two original completed registry unpack roles from
the authenticated original graph and current rows, records real runtime root
stat9 under the held prior root, and uses the existing retained-copy role
surface for the explicit host 100999 / guest 1000 owners. The original helper
catalogue of 365 and selected cache of 381 remain unchanged. Original NAR, mode,
singleton, owner, held FD and stat9 requirements remain in force.

The synthetic regression used the actual `tree_nar` and `postcheck_bindings`
implementations. The exact original package recipes and source metadata were
pinned; only independently encoded synthetic NAR hash/size fields for the two
fixture roots were substituted locally in both fixture row dictionaries. All 13
checks passed:

1. Exact tokio-rustls native role: canonical NAR and postcheck.
2. Exact untrusted native role: canonical NAR and postcheck.
3. Generic route refuses the synthetic top-level Cargo.lock.
4. Changed registered row refuses role binding.
5. Wrong runtime owner refuses.
6. Wrong derived owner refuses.
7. Missing second typed recipe refuses the exact two-root set.
8. Source-row overlap drift refuses.
9. Wrong canonical NAR digest refuses.
10. Postcheck stat9 drift refuses.
11. Cargo.lock in an off-role root refuses.
12. Nested Cargo.lock refuses.
13. Operational .cargo-lock refuses.

The actual report explicitly states synthetic fixture true, cache body reads 0,
archive reads 0, Cargo executions 0, private payload reads 0, qualification
proof false, historical runtime predicate proven false, and actual first runtime
offending file unobserved. The M10 saved generic parent-controller exception
still does not identify its first failed predicate or file. This synthetic PASS
establishes the corrected Source path and guarded refusal behavior; it does not
establish native warm success, Cargo reuse, speed savings or adoption.

The exclusively owned synthetic fixture at
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/tmp/manager11-warm-lock-regression-20261011`
is retained for debugging. Frozen M10 records and Source were not mutated. Next:
complete the original fresh M11 Source controls and original bounded warm route;
retain all existing acceptance criteria and permission boundaries.
