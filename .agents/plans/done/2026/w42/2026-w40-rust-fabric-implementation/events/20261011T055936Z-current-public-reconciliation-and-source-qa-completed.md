# Current public reconciliation and genuine Source QA completed

- Type: validation / closed Source units / current Source evidence
- Coordinator and executor: MAIN
- Source author and saved-result reader: raw_events
- Independent Source reviewer: read_accounting_design

## Closed predecessor units and narrow correction

The first environment-refusal unit and the v2 public128-refusal unit remain
closed and preserved. Each spends its full original25-second Source allowance;
no retry, refund or actual25-second elapsed-time claim is made. Neither launched
BODY or native qualification.

Append-only correction to055339: its statement about no environment key names or
values being queried describes raw_events' author-lane cutoff. MAIN subsequently
reported listing inherited environment **names only** with `compgen -e | rg`,
observing `GIT_PAGER`. No values were read, and the environment guard remained
unchanged. The frozen event is not rewritten.

V2 is retained at
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/.agents/runs/rust-foundation-current-source-reconciliation-v2-source-20261011`.
Its real refs query exited0/reaped, with monitor reservation20,459,825. The real
staged query closed `REFUSED/PUBLIC128`, reaped, with reservation23,818,194 and
remaining limit112,147,583. The exact refused request and offending file were
not recorded; this is not proof that actual source bodies exceeded128MiB. All
four v2 canonical observation files and staged stdout remain empty. raw_events
completely read both actual monitor reports and stderr.

| V2 retained file    | Bytes | SHA256                                                           |
| ------------------- | ----: | ---------------------------------------------------------------- |
| refs.stdout         |    82 | d5c73866efa4cf314059926b68486828b9f67a518778f64ce6115cefce1dbc10 |
| refs.monitor.json   |   370 | 4c7078c9afe864dcdfa1a758e0b7c24620cc12d4d18864543b34b36369c47593 |
| staged.monitor.json |   365 | 493ca14c2e4bd291c1f4832bac7fe5bacb44406f177939cf7aad08081113f7b9 |
| capture.stderr      |  1790 | 7b125562448698a82cfc7a2f11c2917616bb39ceeadd0593ae04abe2a3c144d2 |

## Separately reviewed v3 actual public observation

MAIN consciously selected a separately prepared v3 unit. Its only capture Source
changes from v2 are new `-v3.json` output/receipt basenames and a fixed
command-local `-c core.packedGitWindowSize=1048576`. No monitor, library,
production recipe, compiler flag, acceptance criterion or cap changed.

Official exact Git2.54.0
[`repo-settings.c`134–140](https://raw.githubusercontent.com/git/git/v2.54.0/repo-settings.c)
normalizes the setting to a multiple of twice the page size with a minimum of
two pages. With the existing verified4096 page size,1048576 is preserved.
[`packfile.c`693–709](https://raw.githubusercontent.com/git/git/v2.54.0/packfile.c)
aligns data-window offsets to half the configured size and clamps each new
window's mmap length to that size. This bounds pack **data windows** to1MiB; it
does not bound indexes, MIDX, window count, repeats or total body reads. The
unchanged mode0 monitor permanently accounts aggregate read requests and
mappings. This Source analysis does not diagnose the previous refused request.

The reviewed v3 stage is
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/.agents/runs/rust-foundation-current-source-reconciliation-v3-source-20261011`.
Capture17471 has SHA256
`00352f6330d36018b863890fa1c7ad38376c36c36e55837ceec8da9c881b0233`; isolated
literal bootstrap3167 has SHA256
`90fb179d3146a045385d2df6ac9c5ed3d7b1d847acda8050aa453739f48727be`;
clean-environment command3880 has SHA256
`a985c58730dfd75f9ac040cf72be2d9a7b123dd90ca8ddf7a081c031e2f682ad`. MAIN and
read_accounting_design completed final Source review before MAIN's one actual
externally KILL25 unit. Original limits remain25wall/15CPU/512MiBAS/
oneCPU/file16MiB/publicREAD128MiB, with permanent parent3 plus two monitor6 CPU
partitions. No source/input permission is widened.

Actual v3 closed exit0 `PUBLIC_SOURCE_OBSERVATION_ONLY`, reservation53,717,126,
with both Git queries exit0 and children reaped. Saved outer stdout116 has
SHA256 `0873c9794674ac69aa8509aa6e6c923d5f48bd100cacd864faf41e6e8420e770`;
stderr is empty. Monitor reservations are20,459,825 and31,646,941. raw_events
independently read the complete saved four records, both reports and outer
outputs; their pins and joins agree with MAIN's observations.

Current absolute S is
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/.agents/runs/rust-foundation-initial-manager-20261011`.
The genuine records are:

| S record                    | Bytes | SHA256                                                           |
| --------------------------- | ----: | ---------------------------------------------------------------- |
| current-baseline-v3.json    |   957 | ca8a43c897edc6a9abb08d1637b0c38cd03e722c6ce59a2a335d8859ea4101cf |
| current-event-v3.json       |  1362 | 0950b8aab07b9d2a3cfc018c34049092c60a3fc70114bc26ac2ae565302795ac |
| current-observation-v3.json |  3321 | e07b86feb58a61ae89f8c88dce8ce9dff09b84eb328b7279abb8a71c913b46a4 |
| current-receipt-v3.json     |  1869 | d6c4aafb581db1f9597bae66fb597caafed0db8662226329656157c7a09ae10d |

Git HEAD is `5ae0baf0a7abdac0a5260ae8bfda004fdb01eadd`; master is
`89ba1b801e354421e7f70ef0c83b951107c38ad8`. The current Git index is235384
bytes, SHA256
`fdfae511ee17034d1d808c0db41aaeba095b8cbc819a97ac8eb9c29b63cf5a95`. Staged621 is
a genuine bounded NUL-name metadata count, not an index entry count or inferred
ownership. The complete exact seven public production Source rows carry
same-held-FD hashes and all nine stat fields. Index semantics, author and
change-content dispositions were not interpreted; Git mutation, runtime
authority and protected cache/boot observations are explicitly false.

## Current Source review remains separate from runtime acceptance

read_accounting_design genuinely issued current QA22 Source review and named
normal/optimized evidence. raw_events read these saved values, including the
complete lineage and Source-only scope. Their48 names combine actual current S20
mode observations and authenticated retained O28 mode observations; they are not
a single48-test execution or a fresh current O28 run. Exact O12 pathname
transform and four extracted S fixture AST comparisons support that disclosed
reuse. Final eligible O12 complete review remains a separate gate.

| S evidence                                  | Bytes | SHA256                                                           |
| ------------------------------------------- | ----: | ---------------------------------------------------------------- |
| integration-source-review.json              | 28031 | c863ddd7f8e055408cafbb78082716bae236d22a965cfa947bbebec11371749f |
| current-integration-controls-normal.json    |  3596 | 7d44f0c4072378b8d511be8d61f368d5b65a31ca0dd0afdb819f0b33a1c33402 |
| current-integration-controls-optimized.json |  3599 | b7c06589c9c790fa6af7be03d109d72bbd3bfbe80b24db4be150d037035f1b36 |
| current-control-evidence-lineage.json       |  2763 | f912288282a4eba8886cd2ef3c705b29dd7dbb183354921272a6f8521bf38bfd |
| current-scope-review.json                   |  2805 | c8d10d2078f60d91545d945505c528cf5c75ff573a4a7ad6edd0c3a8fb8fb231 |

The45-entry **Source artifact index**, distinct from the Git index above, is
8372 bytes/SHA256
`41cfade59cda742c228dbdc8502d24f5360bcfd4fd7d13f522245a4409620e85`. It binds
current Source18, original37-limit contract and static support values. Final
eligible S main-launch remains4894 bytes/SHA256
`fb8ec1f28b99474116ca50c38417072cb8633542fa7474f0a70eda9cd40a4c3b`, with every
independent review, manifest, cap, Code and admission gate retained. The
predecessor unarmed loader/index and all frozen records remain unchanged.

These completed Source scopes and current public metadata provide no
initial-manager PASS, physical/private/NAR/WAL custody, BODY grant, native
warm/reuse/locality result, platform cost, immutable integration or adoption.
The next bounded original unit remains final O12 authentic Source binding and
review, then MAIN's original-chain runtime admission/initial manager case under
its original gates. No replacement handles or acceptance criteria are issued.
