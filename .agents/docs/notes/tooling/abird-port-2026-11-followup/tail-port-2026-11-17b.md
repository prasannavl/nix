# Abird tail port — 2026-11-17 (second pass)

Forward port of the Abird (`z`) tail created after
[tail-port-2026-11-17](tail-port-2026-11-17.md). Status: working-tree change
set, not committed, no push, no deployment.

## Boundaries

- Destination base: nix `master` `2f100c51c80c8f70ddbdbad8d515ee92f90afebc`.
- Source: Abird `master` `46c3b6298`, window `f20876d35..46c3b6298` — 5 linear
  commits, no merges. `f20876d35` is the tip ported in the previous pass.
- Abird's worktree had uncommitted edits (`lib/ext/stalwart-cli/sources.nix`,
  one host file); they are not window content and were not read as port state.
  The audit used a pristine `git archive` of `46c3b6298`.

## Commits

| Source      | Subject                                      | Result                                                                                                                                                                                        |
| ----------- | -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `73b479bc3` | chore(nvidia): track driver release branches | Ported: `lib/ext/nvidia/{sources.nix,update.sh}` byte-equal; note merged around local text.                                                                                                   |
| `456a86f60` | chore(forgejo): upgrade to 17.0.1            | Skipped: Abird host file and host note; the destination ships `lib/services/forgejo` with no host consumer.                                                                                   |
| `3b754962e` | chore(zulip): upgrade app broker and cache   | Skipped: Abird host file and host note. The destination `pvl-x2` Zulip deployment is a separate, older pin (`docker-zulip:11.2-0`, rabbitmq 4.0.7); host-local migration, not shared surface. |
| `7da7965d5` | chore(tailscale): use exact Go toolchains    | Ported: three `lib/ext/tailscale` files byte-equal, `go-overlay` root input + lock node + overlay, note byte-equal apart from formatter reflow.                                               |
| `46c3b6298` | chore(nix): trust language toolchain caches  | Ported and adapted: `lib/nix.nix` gains the go-overlay and fenix caches/keys while keeping the local `cache.numtide.com` entry; `lib/tests/default.nix` asserts updated for the combined set. |

## Logical units

| Unit                   | Source      | Scope                                                                                                                                                                                     |
| ---------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NVIDIA branch tracking | `73b479bc3` | `lib/ext/nvidia/sources.nix` (`branch` replaces the unused `kind`), `lib/ext/nvidia/update.sh` (Ajax branch lookup, `--branch`, go/version write-back, report labels), nvidia source note |
| Toolchain cache trust  | `46c3b6298` | `lib/nix.nix`, `lib/tests/default.nix` (5 substituters / 6 keys with the repository registry)                                                                                             |
| Exact Go toolchains    | `7da7965d5` | `flake.nix` input, `flake.lock` node (pinned to `3207e989`), `overlays/default.nix` import, `lib/ext/tailscale/{default,sources,update.sh}`, tailscale note                               |

Adaptation notes:

- `flake.lock` keeps the destination's newer pins; only the `go-overlay` node
  and root input entry were added (17 lines, same shape as the source lock).
- `lib/tests/default.nix` counts differ from Abird because the destination adds
  `cache.numtide.com`/`niks3.numtide.com`: default substituters 5, repository
  registry keys 6. Local `numtide` assertions are retained.
- The tailscale note differs from the source only by `nix fmt` Markdown reflow.

## Verification

- `nix eval .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath`
  and `pvl-a1` — both evaluate; `pkgs.tailscale.version` is `1.104.7`, its src
  is the `v1.104.7` tag, and it builds with `pkgs.go-bin.versions."1.27.4"` from
  the newly pinned overlay.
- `nix build .#checks.x86_64-linux.lib-nix-repo-registry` — passes with the new
  cache asserts.
- `nix eval .#nixosConfigurations.pvl-x2.pkgs.nvidia-custom.version` —
  `595.91.07` (branch `production`, unchanged pin).
- `python3 -m unittest discover -s scripts/support/tests` 153/153,
  `shellcheck`/`bash -n` clean on both updaters.
- `nix fmt` clean; `nix run .#lint -- --diff --base HEAD` exit 0.
- No whole-system build, image build, fleet operation, deployment, live probe,
  secret read or history rewrite.

## Parity snapshot (destination vs `46c3b6298`)

| Tree        |    Equal |   Common |   % | Only nix | Only Abird |
| ----------- | -------: | -------: | --: | -------: | ---------: |
| `lib/`      |      546 |      561 | 97% |       52 |         53 |
| `pkgs/`     |      492 |      509 | 97% |       50 |        478 |
| `overlays/` |        2 |        5 | 40% |        6 |          1 |
| `scripts/`  |       27 |       31 | 87% |        1 |          8 |
| `tf/`       |       56 |       84 | 67% |        1 |          4 |
| **Total**   | **1123** | **1190** | 94% |      110 |        544 |

The 67 differing common paths are unchanged from the previous snapshot and stay
classified as identity/host policy, the retained patched Cargo lane, child-flake
signatures, destination-ahead pins and infrastructure state. No new actionable
shared drift appeared in this window; the four ported `lib/ext` files are now
byte-equal.
