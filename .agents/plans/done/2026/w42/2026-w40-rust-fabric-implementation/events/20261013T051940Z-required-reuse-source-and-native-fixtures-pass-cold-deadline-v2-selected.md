---
type: validation
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-foundation-main
recorded_at: 2026-10-13T05:19:40Z
---

# Required reuse fixtures pass; real manager cold deadline stopped V1

The revised harness passed the required six-case smoke, including existing Nix
cache hit and local binary-cache export/delete/restore with max-jobs=0 and no
remote builders. The optional strict smoke also passed with
checkDeterminism=true. These are harness checks, not manager qualification. The
first smoke preparation failed because substitution was globally disabled; V2
explicitly enables substitution only from the guest-owned local cache during
transport, retaining zero builders. No production trust setting changed.

Current source tests passed 712 assertions. Real Nixpkgs/Crane constructor and
generic forwarding tests passed 247 more; fixture locality passed 27 and
invalidation-target checks passed 18 with 30 construction controls. Existing
mirror generator tests passed 52 and fixture tests 28. Native four-variant
member invalidation passed on regular Cargo: Rust edit changed actual stdout
leaf-v1 to leaf-v2; manifest and lock edits preserved baseline stdout. Full-lock
vendor and compiler contexts were preserved. These bounded fixture/Source
results do not establish Abird 24-member cost or platform runtime acceptance.

Nine core implementation surfaces were compared between R and A; eight match
bytes/modes. pkg-helper retains the documented Abird-specific rustWorkspaceDeps
fallback. Do not overwrite it as a parity fix or claim full Abird qualification.

The new real regular-Cargo manager matrix V1 CLOSED FAILED at its 300-second
aggregate cold-case deadline, exit124, before installed version or cache cases.
Its exact original manager recipe was 97rg1y03xan751brq5mnwrm5gh9v0x4j; 9 tested
outputs were absent per independently seeded guest. The complete log contains
236 compilation messages, 226 external, with dependency-base builds completed
and final real workspace compilation started. No compiler error was issued. This
is a timeout result, not successful manager validation or causal proof about
host contention. The byte determinism gate was disabled throughout.

Select V2 with an explicit 450-second aggregate case deadline and unchanged
1800-second framework timeout, recipes/assertions/cores/memory/source snapshots.
Other native test runs have completed. Do not alter default package/toolchain
identities, seed old manager outputs, reset deadlines per command or call this
original 1CPU/2GiB cost qualification. V1 evidence remains retained separately;
V2 will receive its own result. No archive-reader work or compiler metadata
investigation is selected.
