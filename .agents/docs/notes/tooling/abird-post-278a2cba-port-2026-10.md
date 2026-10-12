# Abird post-`278a2cba` shared port, 2026-10-11

## Boundary and authority

- Previous frozen Abird shared boundary: `278a2cba` (frozen by
  [the post-`278a2cba` audit](./abird-post-278a2cba-audit-2026-09.md)).
- Configured `abird/master` tip at this session: `13dafcde`
  (`style(docs): fix markdown lint drift`), after the remote's forced-update
  rewrite of its earlier `1f4057ee` tip.
- Audit window: `278a2cba..13dafcde`, 87 linear commits, audited commit by
  commit in five parallel read-only subagent lanes plus an independent
  orchestrator-side whole-window shared-path sweep.
- Landing mode: isolated worktree `worktrees/abird-post-278a2cba-port-20261011`,
  branch `agent/abird-post-278a2cba-port-20261011`, based on Pvl `master`
  `e33f9de6`. After review the user approved landing, and the port was applied
  to the main worktree and committed on `master` as the series ending with the
  commit carrying this note. Nothing was pushed or deployed.
- `data/secrets/*.key.age` paths touched by in-window Abird identity/backup
  commits were listed only and never read.

## Logical units ported

1. **Fleet Nix SSH copy isolation** (`2e69c7ea` + `73318b62`, all files
   byte/mode-exact to source): Nix whitespace-tokenizes `NIX_SSHOPTS` without
   shell parsing, so Pvl's original shell-quoting approach could not carry
   routed proxy options, and Nix's own SSH control master bypassed Fleet
   transport authority. Ported `src/fleet/native.rs` (fail-closed
   `nix_sshopts_without_control_master`, `materialize_nix_proxy_command`,
   `prepare_nix_copy_target`, the `nix_copy_target` call sites, and the
   materialization tests), `src/fleet/host_runtime.rs` (`-S none`), and the test
   expectations in `tests/fleet_binary.rs` (`.env_remove("AGE_KEY_FILE")`
   ambient isolation), `tests/fleet_host_runtime.rs`, and
   `tests/fleet_native_runtime.rs`. Pvl's `quote_nix_sshopts` posture is
   superseded; `shell_quote` remains for its other call sites.
2. **`rustWorkspaceDeps` composition seam** (`c50d5c57`, generic parts only,
   byte/mode-exact to source): `lib/flake/pkg-helper.nix`
   (`useWorkspaceDeps ? pkgs.rustWorkspaceDeps or (projectDir != null)`) and
   `lib/flake/stack/package.nix` (`rustWorkspaceDeps ? null` parameter, the
   immutable `policyPkgs` composition contract, and the
   `builtins.seq policyPkgs` validation). Behavior-preserving by default: with
   no policy attrset the outputs are identical to pre-port Pvl.
3. **Agent git signing and push transport note** (`a599e594` + `ee3cf7f4`
   documentation, adapted): new
   [agent-git-signing-and-push-transport-2026-09.md](./agent-git-signing-and-push-transport-2026-09.md)
   adapted with Pvl's `/tmp/nb-*` test temp-root anchoring and a cross-link to
   the stale-cargo-target note. All hook/root-cause statements verified against
   Pvl's byte-identical `.githooks/pre-push` and `scripts/lint.sh`.

## Skipped with reasons

- **Abird identity policy around the rust seam**: `overlays/rust-policy.nix`
  (Abird's default-off 24-member native/WASM/desktop union decision),
  `lib/flake/tests/abird/rust-fabric-policy.nix` and the other
  `lib/flake/tests/abird/*` files (identity test home), and the
  `rustWorkspaceDeps = false` stubs Abird applied to 13 child `flake.nix`
  outputs plus 4 per-crate Cargo feature splits (`clap`/`serde` features stay
  centralized in Pvl's workspace design).
- **Pvl-ahead divergences (do not overwrite)**: host-manager terminal-exit
  teardown (`src/progress.rs`, `src/terminal_mode.rs`, `src/main.rs`,
  `src/bin/nixbot.rs`), builder admission policy (16 lanes vs Abird's abird-ci
  cores pin, `81e7ceb`/`21598f25`), opendesign `pnpm_10_latest` pin,
  update-helper `flake-dirs` Git-ignore-aware discovery (`scripts/update.sh`,
  `scripts/support/update-helper.py` + tests), pi ext pins, and the pi-web
  systemd PATH fix.
- **Reverse-direction commits**: `c50d5c57` core and `3679d7f4` are Abird's
  ports of Pvl-authored work (`d17ffe53`/`9480ac28`, `ed80d052`); `6a89c1d4` is
  Abird's bookkeeping of its own Pvl→Abird port.
- **Abird product/host/docs work**: the memory governed-store series
  (`73601414`…`38ded1ab`, `2fc48bf3`), the abird-agent standing-orders,
  durable-workflows, transactional-child-agents and agency series
  (`d285720f`…`a200d1b1`, all inside `pkgs/srv/abird-agent`,
  `pkgs/support/abird-protocol`, `pkgs/web/abird-web`, `pkgs/apps/abird-app`),
  Abird Garage/backup host work (`e22c8345`, `a1eb5fb6`, `6afef6ad`, `bd1bd398`,
  `90e1b081`, `23e8235e`, `b434085d`, `fd164983`), abird-ci builder bounds,
  phase ledgers/approval docs, and markdown drift/style commits touching only
  Abird-internal notes and plans.
- **AI consumer commits** (`058b095c`, `1ca35bbc`): host/test changes under
  `hosts/abird-*` and `lib/flake/tests/abird/`; Pvl's pvl-x2 librechat consumers
  already carry the equivalent model-id/chat-model filtering.

## Commit-by-commit ledger

| Abird commit                                    | Verdict                                                                                             |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `3dec6dcd` pi-web systemd module                | Already ported (Pvl-ahead: own PATH fix `a00c303a`)                                                 |
| `e0110ddb` tuicr package                        | Already ported (byte-equal; update.sh uses repo-flake helper)                                       |
| `e9307b15` pi-codex-limit extension             | Already ported (byte-equal)                                                                         |
| `6a89c1d4` pvl post-18e548f3 port docs          | Skip: reverse-direction bookkeeping                                                                 |
| `8792fef3` memory 3.7i acceptance               | Skip: Abird docs only                                                                               |
| `24400590` acquire before activation            | Already ported (`038cc8d2`)                                                                         |
| `f40905a6` compact prefetch output              | Already ported (`7b9c93ff`)                                                                         |
| `058b095c` expose endpoint model ids            | Skip: Abird host/test identity; Pvl equivalent present                                              |
| `1ca35bbc` advertise endpoint-owned chat models | Skip: Abird host/test identity; Pvl equivalent present                                              |
| `f492b64c` release leases on caught exit        | Already ported (`38856e56`)                                                                         |
| `f7656c86` consumer admission docs              | Already ported (`b81fc567`)                                                                         |
| `2a1e8cd1` approved-commit ledger               | Skip: Abird internal                                                                                |
| `12dc5549` fleet progress/transport hardening   | Already ported (`38ed1635`)                                                                         |
| `ee403dfb` markdown drift                       | Skip: Abird internal docs                                                                           |
| `2cf856de` fleet dashboard/locks                | Already ported (`ac06366d`)                                                                         |
| `5484bbc8` clippy lint                          | Already ported (`6e443bf3`)                                                                         |
| `a599e594` TMPDIR-trap docs                     | **Adopted** (signing/push note, adapted)                                                            |
| `ee3cf7f4` scrub git env before pre-push        | Already ported (`55c90fe3`)                                                                         |
| `28288177` isolate git repo env in tests        | Already ported (`b67a58ab`)                                                                         |
| `154dca4c` markdown drift                       | Skip: Abird internal                                                                                |
| `dc997d5f` GIT_DIR note wrap                    | Skip: Abird internal                                                                                |
| `61633254` stream safe live host output         | Already ported (`d5c6b3d6`)                                                                         |
| `c2c27023` completed hosts as finalizing        | Already ported (`5ece8c58`)                                                                         |
| `1533612c` controller schema-digest docs        | Skip: Abird internal                                                                                |
| `77d0f200`, `57a22f2f` markdown lint            | Skip: Abird internal                                                                                |
| `73601414` governed store                       | Skip: Abird product crates                                                                          |
| `62f0b268` memory 3.7d                          | Skip: Abird product crates                                                                          |
| `97377ae0` policy/provider binding              | Skip: Abird product crates                                                                          |
| `994f51bc` provider dispatch                    | Skip: Abird product crates                                                                          |
| `04fab3a9` extraction authority ledger          | Skip: Abird product crates                                                                          |
| `368e14ca` proposal workflow                    | Skip: Abird product crates                                                                          |
| `e22c8345` garage admit backup client           | Skip: Abird host (self-cancelling with `90e1b081`)                                                  |
| `38ded1ab` memory 3.7 release prep              | Skip: Abird product/host                                                                            |
| `a1eb5fb6` no-swap cgroup                       | Skip: Abird product                                                                                 |
| `0b537f11` exact reply goals                    | Skip: Abird product                                                                                 |
| `2fc48bf3` memory 3.7 close                     | Skip: Abird docs                                                                                    |
| `35892a1d` output-pipe hang repair              | Already ported (`5fe6f925`)                                                                         |
| `2726b138` markdown drift                       | Adapted-ported (`166854ae`)                                                                         |
| `bc09e4d1` fleet progress refinement            | Already ported (`ea805250`)                                                                         |
| `1b1b9693` typed task/step contract             | Already ported (`60fe1452`)                                                                         |
| `81e7ceb` bound abird-ci memory/cores           | Skip: abird-ci host; Pvl admission policy ahead                                                     |
| `2399738f` lowercase step labels                | Already ported (`80625d60`)                                                                         |
| `21598f25` abird-ci cores 12                    | Skip: abird-ci host                                                                                 |
| `c6a3737b` heartbeats + trim header             | Already ported (`085f4624`)                                                                         |
| `6c2848ff` index wrap                           | Skip: cosmetic, Pvl wrap lint-clean                                                                 |
| `0aa8667d` pulse quiet heartbeats               | Already ported (`573af3da`)                                                                         |
| `45e44243` phase 3.8 acceptance                 | Skip: Abird docs                                                                                    |
| `6afef6ad` Abird Garage host                    | Skip: Abird host; shared carriers carry only abird-fabric registrations                             |
| `bd1bd398` repo to Abird Garage                 | Skip: Abird host/secrets (listed, not read)                                                         |
| `90e1b081` remove Gap3 ingress                  | Skip: Abird host                                                                                    |
| `23e8235e` Garage cutover docs                  | Skip: Abird docs                                                                                    |
| `c591dc50` interactive verbose logs             | Already ported (`07aa3105`)                                                                         |
| `ac027cc5` clear verbose tail                   | Already ported (`da0a1d7f`)                                                                         |
| `b0841a25` lease cleanup exit status            | Already ported (`94403af3`)                                                                         |
| `b5319e3a` Ctrl-C confirm/restore               | Already ported (`14756a9d`)                                                                         |
| `9f8d1614` fleet dependency audit docs          | Already ported (`391df360`)                                                                         |
| `f6825389` markdownlint fix                     | Already ported (`03fc5023`)                                                                         |
| `8c039fa0` in-process fleet tools               | Adapted-ported (`30a15c0a` + `99858ee5` + `8b41d69f`)                                               |
| `b434085d` abird-dev instance limits            | Skip: Abird host config                                                                             |
| `71810c3d` keep log section across views        | Already ported (`b47a0089`)                                                                         |
| `af41317a` reflow + scroll to newest            | Already ported (`be8d2de2` + `63f3ee0f` + `d3f13dca`)                                               |
| `d285720f` standing orders                      | Skip: Abird product crates                                                                          |
| `2e69c7ea` isolate Nix SSH copies               | **Adopted** (byte-exact; Unit 1)                                                                    |
| `fd164983` rotate reset controller repo         | Skip: Abird host/secrets (listed, not read)                                                         |
| `f831e24c` phase 3.8 rollout docs               | Skip: Abird docs                                                                                    |
| `73318b62` isolate age identity                 | **Adopted** (byte-exact; Unit 1)                                                                    |
| `48691759` phase 3.9 advance                    | Skip: Abird docs                                                                                    |
| `6bb82504` durable workflows                    | Skip: Abird product crates                                                                          |
| `2084d14a` Kanidm recovery docs                 | Skip: Abird ops note                                                                                |
| `addc21f4` validate workflow decisions          | Skip: Abird product crates                                                                          |
| `f27930ee` workflow repair docs                 | Skip: Abird docs                                                                                    |
| `5c584449` delegate repository discovery        | Skip: Abird product crates                                                                          |
| `b0789947` discovery deployment docs            | Skip: Abird docs                                                                                    |
| `2de91dd3` retain workflow capabilities         | Skip: Abird product crates                                                                          |
| `0d59f704` live workflow proof docs             | Skip: Abird docs                                                                                    |
| `570db3c5` phase 3.10 advance                   | Skip: Abird docs                                                                                    |
| `05383e53` transactional child agents           | Skip: Abird product crates                                                                          |
| `0eaf39e2` 3.10 deployment docs                 | Skip: Abird docs                                                                                    |
| `20ccf76a` phase 3.11 advance                   | Skip: Abird docs                                                                                    |
| `5a841f0b` agency board and audit               | Skip: Abird product crates                                                                          |
| `a200d1b1` close phase 3                        | Skip: Abird docs                                                                                    |
| `c50d5c57` rust toolchain/cache port            | Core reverse-ported; **generic `rustWorkspaceDeps` seam adopted** (Unit 2); identity policy skipped |
| `3679d7f4` opendesign output checks             | Skip: reverse port of Pvl `ed80d052` (already live)                                                 |
| `1649d221` index entry blurbs                   | Skip: adapted Pvl index already carries shared content                                              |
| `824b6098` index rewrap                         | Skip: Abird-internal                                                                                |
| `13dafcde` markdown lint drift                  | Skip: 11/13 files byte-equal; 2 differ only by fence info-string                                    |

## Review gate after rust fabric completion

Both this port and the `rustWorkspaceDeps`/`policyPkgs` seam carry inline
`REVIEW` markers in `lib/flake/pkg-helper.nix` and
`lib/flake/stack/package.nix`. Once the rust fabric work completes in both
repositories, re-evaluate:

- whether Pvl should define its own repository rust dependency policy overlay
  (Abird's default-off posture is identity-specific and was intentionally not
  adopted);
- whether the seam's defaults and the `policyPkgs` contract survive the unit-DAG
  producer work, or need reshaping;
- whether the markers (and this section) can be resolved.

The exact-set parity hash below was computed before the two inline review
comments were added; the two Nix files therefore intentionally differ from Abird
by those comment blocks only.

## Byte and mode parity audit (post-port, worktree state)

Compared `git ls-tree -r abird/master` blobs/modes against live bytes for all
regular files under `lib/`, `pkgs/`, `scripts/`, `overlays/` (the 7 ported paths
taken from the worktree):

| Area          | Common | Exact | Content differs | Mode differs | Pvl-only | Abird-only |
| ------------- | -----: | ----: | --------------: | -----------: | -------: | ---------: |
| `lib/**`      |    284 |   260 |              24 |            0 |       43 |         23 |
| `pkgs/**`     |    295 |   267 |              28 |            0 |        6 |        295 |
| `scripts/**`  |     42 |    35 |               7 |            0 |        1 |          3 |
| `overlays/**` |      3 |     1 |               2 |            0 |        7 |          1 |
| Total         |    624 |   563 |              61 |            0 |       57 |        322 |

Exact-set SHA-256 over sorted `path<TAB>mode<TAB>blob` rows without a trailing
newline: `3a076f273222c3ddf87d8d50988c8a2388aa25623edbe2aeb7e2bdc2f473fe3d`
(re-audit after landing; the value depends on the uncommitted worktree state).

All 61 content differences are explained: 7 Pvl platform policy, 5 repo
identity, 4 self-reference fetcher policy, 24 Pvl-ahead shared maintenance, 2
overlay policy, 17 Abird rust-foundation adaptation stubs/splits from
`c50d5c57`, 2 builder admission policy. Zero mode differences. Notably several
formerly-divergent areas have converged byte-exact: `lib/images/default.nix`,
`lib/kernel.nix`, `lib/nix.nix`, all 13 `lib/services/ai/**` files, the nginx
compose (both 1.30.5), `pkgs/support/nats-streams/default.nix`, the host-manager
README, and `pkgs/tools/nixbot/tests/test_nixbot.py`.

`lib/ext/revdiff/**` is retired in Pvl (`60de5b2d`) but still present in Abird;
future ports must keep skipping it.

## Validation

- `cargo test -p abird-host-manager -- --test-threads=1` in the worktree: **793
  passed, 0 failed** across 28 test binaries, including the new materialization
  and age-isolation tests.
- `cargo fmt --check`: clean.
  `cargo clippy -p abird-host-manager --all-targets
  -- -D warnings`: 7
  pre-existing lints, all in files or lines untouched and byte-identical on both
  sides (not introduced by this port).
- `alejandra --check` on both ported Nix files: clean. All relevant
  `lib-flake-*` and `pvl-*` checks evaluate to derivations, including
  `pvl-child-flake-parity` (the direct `mkFlakeOutputs` exerciser) and
  `lib-flake-nested-rust-package` (the direct `mkRustDerivation` path).
- `hello-rust`/`hello-rust-isolated` child-flake `packages...default.drvPath`
  evaluate byte-identical to the unmodified-`master` baseline, proving the
  seam's default path is behavior-preserving. An offline `--expr` probe verified
  all four `rustWorkspaceDeps` contract branches (null passthrough, policy
  injection via `pkgs.extend`, agreement passthrough, and the exact disagreement
  throw), and that an injected policy demonstrably reaches `mkRustDerivation`'s
  `useWorkspaceDeps` default.
- `git diff --check`: clean.

## Forward-port candidates (Pvl → Abird, next boundary sync)

- pi-web systemd PATH fix (`a00c303a`), current pi ext source pins and
  `update.sh` improvements, host-manager terminal-exit teardown
  (`progress.rs`/`terminal_mode.rs`/`main.rs`/`nixbot.rs`), update-helper
  `flake-dirs` Git-ignore-aware discovery, opendesign `pnpm_10_latest`, and the
  builder 16-lane admission policy.
