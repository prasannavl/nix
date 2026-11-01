# Auxiliary evaluation source-ref correction

- Batches 05–07 originally passed Git-aware CLI
  `nix flake check . --all-systems --no-build` with IFD disabled.
- Their additional JSON extraction used bare absolute `builtins.getFlake`
  references. Repeat that extraction with explicit `git+file://` review refs;
  this corrects the auxiliary source-ref method, not the successful CLI gates.
- Before approved retirement, each corrected evaluation forced all 175 check
  derivations: 88 x86 Linux, 87 ARM Linux, zero Darwin. No builds or IFD.
- Original review HEADs/indexes/files remained unchanged. Verified trees:
  - 05: `afab9d16690126f9afb412cb08258dff92655e17`.
  - 06: `261c659ef326c184f5d3306bae9e89f197ccedbc`.
  - 07: `c9e4c03e25beb122628bc4383c075292d15a8ce3`.
- Historical reports/events are unchanged. This append-only receipt supersedes
  only the auxiliary extraction method; no private product acceptance claim.
