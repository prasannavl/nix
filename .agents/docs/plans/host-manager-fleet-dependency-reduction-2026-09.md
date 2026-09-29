# Abird Host Manager Fleet Dependency Reduction Plan

## Status

Planned 2026-09-28 in worktree
`worktrees/host-manager-fleet-dep-reduction-20260928` (branch
`agent/host-manager-fleet-dep-reduction-20260928`). WP1-WP6 are implemented
there; the Abird replay is recorded in `## Cross-Tree Portability` below. This
plan supersedes the `WP3b` native SSH-KEX sketch in
`.agents/docs/notes/tooling/abird-host-manager-fleet-dependency-audit-2026-09.md`;
the audit's inventory and classification remain the evidence base.

### Landed on master (2026-09-29)

Rebased onto `master` `74821d3b`, which had moved ahead with the output-UX
`errors view` work and the workspace dependency-feature normalization. The
rebase was conflict-free: master had not touched `Cargo.lock`, and its
`Cargo.toml` edits were in upstream lines this branch does not change.

Two fixes were required to make the package's canonical Nix checks green,
because the branch had only been validated with a bare `cargo test` on a real
NixOS host:

- `src/programs/age.rs` dropped a redundant `&contents[..]` slice
  (`clippy::redundant_slicing`, denied under the package lint check).
- `tests/fleet_native_runtime.rs::local_self_target_deploy_uses_an_isolated_known_hosts_file`
  now passes `--no-rollback`. Its full local deploy ran the absolute target tool
  `/run/current-system/sw/bin/readlink` in the snapshot phase, which exists on a
  NixOS host but not in the Nix build sandbox; disabling rollback skips the
  snapshot phase while the test still asserts the isolated `ssh-ng://`
  `known_hosts` copy.

Repository rule that follows: package integration tests that drive the real
binary must not depend on absolute `/run/current-system/...` tools, because
`nix build .#<pkg>.passthru.checks.test` runs in the Nix sandbox.

Validation on the rebased branch: `nix build .#abird-host-manager`,
`.passthru.checks.fmt`, `.passthru.checks.lint`, and `.passthru.checks.test`
(337 lib + all suites) all pass.

## Summary

Shrink the external runtime dependency surface of the `abird-host-manager`
binary for its `fleet` commands from the inherited Bash `nixbot` tool set down
to the irreducible controller tools, without weakening host-key trust or the
ability to bootstrap a host that does not yet have a `nixbot`/
`abird-host-manager` closure.

Three tiers land:

- **Tier 0** dependency metadata cleanup.
- **Tier 1** controller-local in-binary replacements (libc).
- **Tier 2** `age` crate, native `ssh-keygen`, `ssh-keyscan` removed by unifying
  on `ssh` + `StrictHostKeyChecking=accept-new`, and target-side `jq` removal.

**Tier 3 stays wrapped**: `nix`, `git`, `ssh`/`openssh`, `tofu`, `cloudflared`.

`fleetRuntimeInputs` goes from 15 packages to 5. `REQUIRED_PROGRAMS` goes from
14 to 4.

## Current Baseline

Evidence is recorded in
`.agents/docs/notes/tooling/abird-host-manager-fleet-dependency-audit-2026-09.md`.
Condensed:

- `pkgs/tools/abird-host-manager/default.nix` `fleetRuntimeInputs`: `age`,
  `cloudflared`, `coreutils`, `findutils`, `gawk`, `git`, `jq`, `getent`,
  `inetutils`, `iproute2`, `nix`, `openssh`, `opentofu`, `procps`, `util-linux`.
- `pkgs/tools/abird-host-manager/src/fleet/maintenance.rs` `REQUIRED_PROGRAMS`:
  `nix`, `age`, `cloudflared`, `git`, `jq`, `nproc`, `pgrep`, `ssh`, `scp`,
  `ssh-keyscan`, `ssh-keygen`, `stty`, `timeout`, `tofu`.
- Three resolution surfaces: controller PATH (above), target SSH scripts
  (`PATH=/run/wrappers/bin:/run/current-system/sw/bin`), and embedded Bash.
- NixOS `corePackageNames` already guarantees on every target: `bash`,
  `coreutils-full`, `findutils`, `gawk`, `getent`, `gnugrep`, `gnused`,
  `gnutar`, `procps`, `util-linux`, `curl`, `diffutils`. `jq`, `iproute2`,
  `inetutils`, `podman`, `age`, `tofu`, `cloudflared` are **not** core.
- Controller-local shell-outs to replace: `hostname`, `ip`, `getent`, `id`
  (`native.rs::self_target_evidence`), `env` (`native.rs::with_nix_sshopts`),
  `timeout` (`host_runtime.rs::run_bounded_read`), `age` (5 sites), `ssh-keygen`
  (2 sites), `ssh-keyscan` (3 sites).
- Unused/legacy: `nproc`, `pgrep`, `scp`, `stty`, `find` (test only), `ps` (only
  via remote `podman ps`).

## Decisions And Constraints

Decisions already made with the operator:

- **Design 1 for host keys.** Drop `ssh-keyscan`; keep the `ssh` binary and use
  the accept-new path it already uses for proxied routes. Do not implement a
  native SSH key-exchange scanner.
- Keep `ssh`/`openssh` wrapped. The external OpenSSH CLI is a hard contract for
  Nix `ssh-ng://` stores, git `GIT_SSH_COMMAND`, target-side `rsync -e` and the
  broker lane, and interactive `host ssh`/`host exec` passthrough.
- Keep `cloudflared` and `tofu` wrapped. A separate Terraform-only output is
  deferred.
- The active Bash `nixbot` at `pkgs/tools/nixbot/default.nix` keeps its full
  `runtimeInputs` until the separate cutover. Only `abird-host-manager` shrinks
  now; the divergence is recorded as a cutover task.
- No external overrides for replaced programs. `ABIRD_HOST_MANAGER_AGE` and the
  compile-time `ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM` are removed; `age`
  always decrypts in-process. The same rule applies to every program replaced by
  a native library or in-binary logic.
- Do not read `data/secrets/**/*.key`.

Overrides intentionally kept are only for programs that stay wrapped:
`ABIRD_HOST_MANAGER_NIX`, `_GIT`, `_SSH`, `_NIXOS_INSTALL`,
`_NIXOS_GENERATE_CONFIG`, `_PRIVILEGE`, `_PUBLISH_GIT_SSH_COMMAND`.

Additional constraints:

- `abird-host-manager` is a shared package mirrored from Abird. This work is a
  Pvl-side change until mirrored; record the parity divergence.
- No pre-activation remote script may depend on a manager-only tool.

## Cross-Tree Portability (Abird)

Verified and replayed 2026-09-29 against the Abird main tree at
`/home/pvl/spaces/abird/src/z` (branch `master` `f6825389` plus its uncommitted
output-UX WIP):

- The Pvl worktree is based on `master` `03fc5023`. The committed
  `pkgs/tools/abird-host-manager/**` package is byte-identical between Pvl
  `03fc5023` and Abird `f6825389`; the only on-disk difference is an empty,
  untracked `tests/fixtures/` directory in Abird with no files.
- Root `Cargo.toml`/`Cargo.lock` differ because Abird's workspace lists many
  more members; the `abird-host-manager` package manifest itself is identical.

Replay (2026-09-29): the whole WP1-WP6 package diff was applied to Abird's
working tree with `git apply`. Abird's uncommitted output-UX WIP hunks did not
overlap any WP change, so no conflict arose and the WIP was preserved.
`pkgs/tools/abird-host-manager/**` is byte-identical between the trees for every
file except Abird's independent WIP: `src/fleet/interactive.rs`,
`src/fleet/presentation.rs`, `src/progress.rs`, `src/terminal_style.rs`, and
`README.md`. Abird's root `Cargo.toml` received the same
`age`/`ssh-key`/`zeroize` workspace deps, and its `Cargo.lock` was regenerated
additively (no existing package version changed).
`cargo test -p
abird-host-manager` in Abird passes (321 lib + all suites).
`docs/deployment.md` also received the same host-key-pinning qualifier; it is a
shared repo doc outside the strict package replay scope. `.agents/docs/**` is
Pvl-only and was not replayed. Full package byte parity is blocked only until
Abird's output-UX WIP is committed or otherwise reconciled.

Design rules for 1:1 parity:

- Every change stays inside `pkgs/tools/abird-host-manager/**` and must be
  tree-neutral: no Pvl-specific host, stack, path, or user names, and no
  repo-root-relative assumptions.
- After landing, `pkgs/tools/abird-host-manager/**` must be byte-identical
  between the two trees.
- The shared package's `Cargo.toml` and `default.nix` are byte-identical and can
  be copied directly. The root `Cargo.toml` gets the same
  `[workspace.dependencies]` additions in each tree, and each tree regenerates
  its own root `Cargo.lock` (`cargo update`/`cargo add`) because the lockfiles
  already differ by workspace membership.
- Apply the change to one tree first, validate there, then replay the same
  file-level edits to the other and confirm byte parity before recording the
  parity note.

## Goals

- Remove packages that the Rust code no longer needs from the controller wrapper
  and the dependency check.
- Replace controller-local shell-outs with in-binary logic where a Rust crate or
  `libc` exists and behavior can be preserved.
- Remove the only non-core tool used by a target-side remote script (`jq`).
- Keep host-key trust, mutation ordering, and bootstrap semantics intact.

## Non-Goals

- Do not replace `nix`, `git`, `ssh`, `tofu`, or `cloudflared`.
- Do not change `pkgs/tools/nixbot/**` or the active Bash path.
- Do not change the non-fleet `agent_adapter` host-key mechanism
  (`host_key_check` + `host_public_keys`, `ssh-host-key` retrieval); it never
  used `ssh-keyscan`.
- Do not weaken `StrictHostKeyChecking` semantics: `accept-new` accepts only
  unknown keys and still rejects changed keys.
- Do not add an async runtime, `russh`, `ssh2`, or a native KEX implementation.

## Dependency Inventory: Before And After

| Package             | Used for                                          | Disposition                |
| ------------------- | ------------------------------------------------- | -------------------------- |
| `nix`               | core engine (`eval`, `build`, `copy`, `add-root`) | Keep                       |
| `git`               | repository clone/fetch/commit/push/worktree       | Keep (Tier 3)              |
| `openssh` (`ssh`)   | transport, ProxyCommand, agent forwarding, mux    | Keep (Tier 3)              |
| `opentofu` (`tofu`) | `fleet terraform`/`fleet tofu` effect             | Keep (Tier 3)              |
| `cloudflared`       | user `proxy_command`                              | Keep (Tier 3)              |
| `age`               | decrypt `.age` identities/tfvars                  | Replace with `age` crate   |
| `coreutils`         | target scripts + local `env`/`readlink`/`timeout` | Drop; core + in-binary     |
| `gawk`              | target pre-switch/health `awk`                    | Drop; NixOS core on target |
| `util-linux`        | target `flock`/`setpriv`/`timeout`                | Drop; core + in-binary     |
| `findutils`         | none in production                                | Drop                       |
| `procps`            | none in production                                | Drop                       |
| `getent`            | local `ahosts` + target scripts                   | Drop; `getaddrinfo` + core |
| `inetutils`         | local `hostname`                                  | Drop; libc `gethostname`   |
| `iproute2`          | local `ip`                                        | Drop; libc `getifaddrs`    |
| `jq`                | target health collector only                      | Drop; parse in Rust        |

`ssh-keygen`/`ssh-keyscan` are invocations from `openssh`, not separate
packages; removing them does not change the closure but removes the direct
dependency and lets `REQUIRED_PROGRAMS` shrink.

`REQUIRED_PROGRAMS` after: `git`, `nix`, `ssh`, `tofu`.

## Design 1: Host-Key Trust Unification

Current behavior is a hybrid (`native.rs::prepare_known_hosts`,
`transport.rs::SshRoutePlan`, `bootstrap.rs::known_hosts_plan`):

| Route                              | Scan today                             | Policy today                              |
| ---------------------------------- | -------------------------------------- | ----------------------------------------- |
| Configured `known_hosts`           | none                                   | `Strict` (direct) / `AcceptNew` (proxied) |
| Direct (no proxy)                  | `ssh-keyscan` target, ed25519 then any | `Strict`                                  |
| Proxy chain, scannable first hop   | `ssh-keyscan` first hop                | `AcceptNew`                               |
| `ProxyCommand` (cloudflared)       | none                                   | `AcceptNew`                               |
| Chained jump hops (inner `ssh -W`) | n/a                                    | `AcceptNew` (hardcoded)                   |

Both mechanisms are Trust On First Use. `ssh-keyscan` is an unauthenticated
out-of-band observation; `accept-new` is an unauthenticated observation on the
real connection. The scan adds an extra live connection and, on OpenSSH 10.5
servers with default `PerSourcePenalties`, accrues `noauth` penalties; the
incident in `notes/nixbot/build-host-known-hosts-route-failure-2026-09.md`
identifies repeated live scanning as the wrong liveness mechanism.

After Design 1:

- The scan is deleted. `prepare_known_hosts` keeps only the configured-pin and
  empty-file paths.
- All routes use `HostKeyPolicy::AcceptNew` into the isolated `0600` known-hosts
  file (`-F /dev/null`, `GlobalKnownHostsFile=/dev/null`).
- Configured inventory `known_hosts` still seeds the file and remains an
  authenticated pin; `accept-new` verifies against it and rejects changes.
- The cloudflared/proxy cases are unchanged (already `accept-new`), which is the
  proof that the model works for both proxied and direct transports.
- Bootstrap is unchanged in trust: the first real connection to an unmanaged
  host pins the key; changed keys are rejected. The only difference is losing
  the fail-fast pre-pin, which was itself an unauthenticated observation.

Behavior deltas to document:

- Direct routes move from "pre-scan + `Strict`" to "`accept-new` on first use".
- `host_key_policy` is part of the ControlMaster socket digest
  (`native.rs::ssh_route_digest`) and the builder-lease route authority
  (`host_runtime.rs::lease_route_authority`); both are per-run, so the digest
  change has no cross-version durability impact.
- Known-hosts entries become plain (no `ssh-keyscan -H` hashing); the files are
  private and short-lived.

## Work Packages

### WP0 — Worktree and validation scaffolding

- Work in `worktrees/host-manager-fleet-dep-reduction-20260928`.
- Baseline: `cargo test -p abird-host-manager`,
  `nix build .#abird-host-manager`, and `nix path-info -S` closure size.
- Keep the audit note as evidence; this plan is authoritative for design.

### WP1 — Metadata cleanup (Tier 0)

Files:

- `pkgs/tools/abird-host-manager/default.nix`
- `pkgs/tools/abird-host-manager/src/fleet/maintenance.rs`

The two test files below need no change: they enumerate `REQUIRED_PROGRAMS`
generically or filter `age`/`git`/`nix`, so they follow the list automatically.

- `pkgs/tools/abird-host-manager/tests/fleet_maintenance.rs` (no change)
- `pkgs/tools/abird-host-manager/tests/fleet_binary.rs` (no change)

Changes:

1. Drop `procps` and `findutils` from `fleetRuntimeInputs` (no production
   caller; both are NixOS core on the controller).
2. Narrow `REQUIRED_PROGRAMS` to `age`, `git`, `nix`, `ssh`, `ssh-keygen`,
   `ssh-keyscan`, `tofu` for the intermediate state, with a doc comment stating
   the invariant (controller-local, non-core, unconditional spawn sites). Drop
   `cloudflared` (conditional), `jq` (target-side), and
   `getent`/`nproc`/`pgrep`/ `scp`/`stty`/`timeout` (NixOS core or unused).

Validation: `cargo test -p abird-host-manager`; `fleet check-deps` under the
wrapped PATH; `nix path-info -S` before/after.

### WP2 — Controller-local in-binary replacements (Tier 1)

Files:

- `src/fleet/native.rs` (`self_target_evidence`, `with_nix_sshopts`)
- `src/fleet/host_runtime.rs` (`run_bounded_read`, `ProcessExecutor`)
- new `src/fleet/system_identity.rs` (libc helpers)
- `default.nix`

Changes:

1. Replace `self_target_evidence` shell-outs with a libc module:
   - `local_host_aliases()`: `gethostname`, short form, canonical FQDN via
     `getaddrinfo(AI_CANONNAME)` — replaces `hostname`, `hostname -s`,
     `hostname -f`.
   - `local_ip_addresses()`: `getifaddrs` walk — replaces `ip -o addr show up`.
   - `resolve_peer_addresses()`: `getaddrinfo`/`ToSocketAddrs` — replaces
     `getent ahosts`.
   - `effective_uid()`/`current_user()`: `geteuid`/`getpwuid_r` — replaces
     `id -u`/`id -un`.
2. `with_nix_sshopts`: return the command plus an environment vector; add
   `execute_local_command_with_env` (or extend `CommandSpec`) instead of the
   `env` wrapper. Preserve `NIX_SSHOPTS` exactly.
3. `run_bounded_read`: replace external
   `timeout --foreground --signal=TERM
   --kill-after=5s` with an in-process
   deadline on the child process group (TERM, then KILL after 5s, status 124 on
   expiry), reusing `process_group(0)`.
4. Drop `coreutils`, `getent`, `inetutils`, `iproute2`, `util-linux` from
   `fleetRuntimeInputs` after 1-3 are green.
5. Update `pkgs/tools/abird-host-manager/README.md` self-deployment sentence at
   line 314 that claims the package carries hostname/address-discovery tools.

Risks: unsafe libc wrappers are contained in one module with pure-parsing unit
tests; the timeout must not kill the SSH control master or unrelated processes.

Validation: alias/address parsing tests; a `run_bounded_read` deadline test;
`with_nix_sshopts` environment test; existing `native`/`deploy` tests.

### WP3 — `age` crate (Tier 2)

Files: `Cargo.toml`, `Cargo.lock`, `src/programs/age.rs`, `src/ssh_runtime.rs`,
`src/fleet/ci_runtime.rs`, `src/fleet/terraform_runtime.rs`,
`src/fleet/native.rs`, `default.nix`.

Changes:

1. Add RustCrypto `age` with the `ssh` feature; refresh `Cargo.lock`.
2. One decryptor parses each identity as `age::x25519::Identity` or
   `age::ssh::Identity` and decrypts in-process, serving all five sites:
   `programs/age.rs`, `SshRuntime::resolve_identity`,
   `AgeOrFileCredentialMaterializer`, `AgeCommandDecryptor`,
   `materialize_declared_key`.
3. Remove the external-CLI override entirely: delete the
   `ABIRD_HOST_MANAGER_AGE` runtime lookup and the
   `ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM` compile-time default; `age` decrypts
   in-process with no fallback.
4. Drop `age` from `fleetRuntimeInputs` and `REQUIRED_PROGRAMS`, and drop the
   `ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM` build attribute from `default.nix`.
5. Preserve caller destination modes (`0600`/`0440`), identity ordering, and
   error wording asserted by tests.

Risks: no `age-plugin-*` recipient support in-process (accepted and documented;
there is no override); passphrase-protected identities stay a non-interactive
failure; new transitive crates must resolve in the offline Crane vendored build.

Validation: in-process round-trip (encrypt in-test to a generated x25519
recipient), an SSH-identity fixture, and existing
`ssh_runtime`/`terraform_runtime`/`ci_runtime` tests. Add a test asserting the
removed env vars no longer change behavior.

### WP4 — Native `ssh-keygen` and `ssh-keyscan` removal (Tier 2)

#### WP4a — `ssh-keygen` -> `ssh-key`

- Add `ssh-key`; no `rand` needed (parse only).
- `native.rs::prepare_bootstrap_public_key` (`:1565`, `ssh-keygen -y`): parse
  `PrivateKey::from_openssh`, derive `public_key().to_openssh()`.
- `native.rs::run_bootstrap_check_phase` (`:3297`, `ssh-keygen -lf`): use
  `public_key().fingerprint(HashAlg::Sha256)` directly; drop stdout field
  parsing.
- Encrypted private keys stay a non-interactive failure.
- Tests: `tests/fleet_native_runtime.rs:1142` uses an `ssh-keygen` fixture;
  replace with in-process assertions and ed25519/RSA fixtures.

#### WP4b — `ssh-keyscan` -> `accept-new` (Design 1)

- `native.rs::prepare_known_hosts`: delete the `scan_host` computation and the
  `ssh-keyscan` loop; keep the configured-contents write and the empty
  `create_new` file creation.
- Local (self) targets also receive the isolated known-hosts file: they still
  push over `nix copy --to ssh-ng://`, so `accept-new` must never fall back to
  the operator's ambient trust store. Covered by
  `local_self_target_deploy_uses_an_isolated_known_hosts_file`.
- `transport.rs::SshRoutePlan::direct`: `HostKeyPolicy::Strict` ->
  `HostKeyPolicy::AcceptNew`.
- `bootstrap.rs`: remove `ScanAlgorithm`, `KnownHostScan`, `scans_for`, and the
  `KnownHostsPlan.scans` field; `known_hosts_plan` yields no scans and
  `AcceptNew` for every route; keep `KnownHostsInput`/`KnownHostsSeed`/
  `SshHostKeyPolicy`.
- `runtime.rs::repository_manager`: delete `scan_repository_host_key`; always
  create an isolated known-hosts file when one is not configured.
- `repository.rs::repo_git_ssh_command`: `StrictHostKeyChecking=yes` ->
  `StrictHostKeyChecking=accept-new`.
- `ci_runtime.rs`: remove `CiPrograms.ssh_keyscan` and the `CiPrograms::new`
  argument; remove the keyscan block; when no configured known-hosts is present,
  write an empty file and use `accept-new`; remove
  `CiExecutionReport.used_keyscan` and its callers/tests.
- Drop `ssh-keygen`/`ssh-keyscan` from `REQUIRED_PROGRAMS`; `openssh` stays for
  `ssh`.

Tests to update:

- `tests/fleet_bootstrap.rs` — `SshHostKeyPolicy::Strict`/`ScanAlgorithm`
  assertions become `AcceptNew` with no scans.
- `tests/fleet_transport.rs:165` — direct route expectation.
- `tests/fleet_repository.rs:369` — strict-string assertion.
- `tests/fleet_native_runtime.rs:681-798` — remove the keyscan log/fixture and
  proxy-command scan assertion; assert no scan process is launched.
- `tests/fleet_ci_runtime.rs` — `CiPrograms::new` arity and `used_keyscan`.

Risks: known-hosts behavior change is intentional; cover the direct and
ProxyCommand paths with a fake `ssh` tool that records argv so the absence of a
scan and the presence of `accept-new` are asserted.

### WP5 — Remove target-side `jq` from health (Tier 2)

Files: `src/fleet/health_runtime.rs`, `default.nix`,
`tests/fleet_health_runtime.rs`, `tests/fleet_native_runtime.rs`.

Design: keep one collector round-trip; move hold logic to Rust.

1. Remove `held_tsv`, the `jq` pipeline, every `--exclude-unit`, and the
   `role=held` unit query from `HEALTH_COLLECTOR`. Enumerate users from
   `/etc/systemd/user/*-managed.target` only; emit all declared units as
   `expected`.
2. In `check_managed_health_with_progress`/`classify_observation`, use the
   already-parsed `hold_response` (`holds_by_user`) to reclassify matching
   `expected` snapshots as `held` and to add held-only users.
3. Keep emitting `hold-response`; keep `validate_durable_holds`.
4. Remove `jq` from `fleetRuntimeInputs` and assert no embedded script
   references it.

Fallback: if held-unit parity is hard, run `abird-host-agent --json hold list`
as a separate bounded remote command and pass held pairs into
`managed_health_command` as quoted arguments.

Risks: held-unit parity; verify `podman-composectl expected-units` returns
declared units without `--exclude-unit`.

Validation: held/system/user classification tests; script-text assertions that
no embedded script references `jq` and that held pairs reach the collector as
argv; one live deploy with an open user-service hold.

Landed via the documented fallback (2026-09-29): a separate bounded
`abird-host-agent --json hold list` probe transports the hold JSON to Rust, and
held `user<TAB>unit` pairs are replayed to the collector as argv. The literal
one-round-trip design cannot preserve `expected-runtime` parity because its
output lines name services, not units, so held (deliberately stopped) auto-start
units must be filtered target-side with `--exclude-unit`. Consequences: one
extra bounded read-only remote exec per health attempt, a failed probe aborts
the attempt before the collector runs, and in `fleet run --dry` the read-only
probe is not skipped, so dry runs issue one extra real remote read per health
attempt.

### WP6 — Closeout

1. `fleetRuntimeInputs` becomes `cloudflared`, `git`, `nix`, `openssh`,
   `opentofu`.
2. `REQUIRED_PROGRAMS` becomes `git`, `nix`, `ssh`, `tofu`.
3. Update `pkgs/tools/abird-host-manager/README.md` and the audit note status.
4. Record the `nixbot`/`abird-host-manager` runtime-input divergence.
5. Replay the same file-level edits to the Abird tree, regenerate its root
   `Cargo.lock`, and confirm `pkgs/tools/abird-host-manager/**` byte parity
   before recording the parity note. Only `pkgs/tools/abird-host-manager/**` is
   replay content; `.agents/docs/**` is Pvl-only and is never copied to Abird.

## Bootstrap Safety

The first deploy to an unmanaged host runs only:

1. `snapshot_command` (`readlink -f /run/current-system`) — core.
2. `generation_admission_command` and `pre_switch_preparation_command` — bash,
   `awk`, `systemctl`, `loginctl`, `setpriv`, `id`, `sort` — all core.
3. activation via the candidate `switch-to-configuration` — core.
4. candidate GC lease — bash, `nix-store`, `readlink`, `mkdir`, `rm` — core.
5. health collection — currently `jq`; WP5 removes it.

Rules:

- No pre-activation remote script may depend on `age`, `git`, `tofu`, or `jq`.
- A wrapper entry is removed only after its Rust replacement lands and the
  caller no longer spawns the binary; otherwise local self-target execution
  breaks.
- `accept-new` keeps bootstrap working for direct and cloudflared routes; the
  first connection to an unmanaged host pins the key and later connections
  reject changes.
- `check-bootstrap` still uses the `ssh` route; `ssh-keygen` becomes in-process
  under WP4a.

## Validation Plan

Static and unit:

- `cargo test -p abird-host-manager` (all suites, including `fleet_maintenance`,
  `fleet_binary`, `fleet_bootstrap`, `fleet_transport`, `fleet_repository`,
  `fleet_native_runtime`, `fleet_ci_runtime`, `fleet_health_runtime`,
  `fleet_deploy`, `fleet_host_runtime`).
- `nix build .#abird-host-manager`.
- `nix run .#abird-host-manager -- fleet check-deps` against the reduced list.

Behavioral:

- `fleet run --dry` on a multi-host selection; assert the generated remote
  command set is unchanged except for the intended host-key policy.
- Fake-`ssh` argv test proving no `ssh-keyscan` is launched and `accept-new` is
  passed for direct and ProxyCommand routes.
- One live deploy on a spare or low-risk host, including a host without `jq` in
  its system packages.
- A live deploy with an open user-service hold to exercise WP5.
- Cloudflared-routed deploy to confirm the proxied path still works unchanged.

Metrics:

- `nix path-info -S .#abird-host-manager` closure shrink per tier.
- `fleet check-deps` output lists only `git`, `nix`, `ssh`, `tofu`.

## Rollout And Ordering

1. WP0 baseline.
2. WP1 lands alone (metadata only).
3. WP2 lands per replacement; each wrapper input is dropped only after its
   caller is green.
4. WP3 and WP4 are independent after WP1; WP4b (Design 1) should land before any
   target cutover.
5. WP5 is the highest-value target fix; land before cutover.
6. WP6 closes out.

Each work package is a candidate commit unit; keep shared code separate from
per-repository wiring and keep docs/tests with the unit they explain.

## Open Questions

- Should `bootstrap::known_hosts_plan` be made the single planner used by
  `native::prepare_known_hosts`, or remain a test-only contract? (Plan removes
  the scan-specific parts either way.)
- When to mirror this Pvl-side reduction to Abird (plan requires replay plus
  byte-parity confirmation).
- When to schedule `gix`/`russh` work; both remain out of scope.

## Handoff Notes

- Implement in `worktrees/host-manager-fleet-dep-reduction-20260928`; do not mix
  with the in-flight `interactive verbose`/output-UX work on `master`.
- Apply the finished change to both trees from the same file-level edits; the
  shared package must end byte-identical. Regenerate each root `Cargo.lock`.
- No external override survives for a replaced program; only kept tools retain
  their environment overrides.
- Do not change `pkgs/tools/nixbot/**`; that is the cutover task.
- Keep `.agents/docs/README.md` synchronized if this plan moves, splits, or is
  completed.
- Do not read `data/secrets/**/*.key`.
