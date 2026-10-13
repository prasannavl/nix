---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
status: bounded-artifact-comparison-closed-success-root-cause-unproved
---

# M23 bounded archive comparison succeeded and closed

After complete Main and independent Source/caller/live-ELF review, Main executed
the newly bound V6 comparison exactly once. It CLOSED SUCCESS, exit 0/empty
stderr. Root and the independent reviewer authenticated full9 joins, actual
aggregate reports and closure. This is bounded comparison evidence for the exact
previously selected expected/retained pair, not a new manager PASS.

Actual controller stdout: 712 bytes, SHA256
`a690241cdb885818a7fd68b3505d89c217d1647c5bc825cfc6011f8a9c3ad305`. Comparator
aggregate stdout: 1,430 bytes, SHA256
`2cc1b6ee03df0310a6b7e1d0dffc6261bd53f10775b12053e1f33d064ad01cd0`. Monitor
receipt: 372 bytes, SHA256
`1ce2bfec74bf9d17b0b899c54fe8568010b751cedb819311a89cb36b525929e7`. The
unchanged mode0 child exited 0, was reaped and reported violation NONE: 4,258
calls, 64 maps and 93 metadata operations. Its 5,290,449-byte kernel reservation
was counted once. Child READ is 98,472,199 bytes; known aggregate requests are
98,733,304, within the original 134,217,728-byte limit. No monitor policy or
read cap was changed to obtain success.

The two native compressed bodies total 53,213,209 actual bytes and 53,213,211
requests including EOF. Each archive has 80 entries/headers, 89,354,240 decoded
bytes and 18,788 metadata bytes. The entry set is identical: zero additions and
zero removals. There are 11 metadata differences and 15 regular-payload
differences: seven dependency-info, six executable/library and two other;
fingerprint/build-script payload differences are zero. Difference classes are
`entry_metadata` and `regular_payload`. Tar byte equality, logical map equality
and compressed equality are false. This rules out an order-only explanation for
the observed archive heads, without identifying differing fields or their root
cause.

Same `.prev` parent semantics were checked without reading parent bodies.
Full-tree equality is None, global certainty false and qualificationPassed
false. No raw payloads, private filenames/paths, fingerprint values or carriers
were emitted; no extraction, recipe/hook mutation or artifact execution
occurred. The admitted hash-only scope does not establish semantic contents of
the differing dependency-info or executable payloads.

The original wrapper target was selected directly using authenticated public ELF
and isolation preflight. Paired opaque context observations matched 79 modules
and 57 Source files, establishing the relevant standard-library equivalence for
this case, not a global startup certificate. The controller is 14,411 bytes,
original interpreter 15,776 bytes and public preflight 1,369 bytes; their
complete current pins were independently reviewed before execution.

All previous failed cases remain closed and unchanged: M23 native FAILED with
fully spent native300, old V3 comparison/refusal with spent Source25, and public
wrapper compatibility findings. Neither V6 nor earlier Sources/commands may be
replayed or refunded. CargoFresh remains not_observed; provenance and required
goal acceptance remain false. M21 manager/version PASS and M22 failure remain
the original recorded results.

Next is Source-only public recipe/build-context review using unchanged original
Cargo/Crane hooks, build CWD/remapping and transport semantics. Any deeper
dependency-info/ELF/tar-field parsing needs a separately selected finite scope,
complete read-surface/Source/caller/control and independent peer review before
more artifact reads. The 123600 hash-only scope cannot implicitly grant semantic
payload parsing. No field or production correction is selected by these
aggregate differences alone. All G1-G11, cost/Abird/platform/mirror and separate
integration/adoption gates remain open; no push, merge or default adoption
follows.
