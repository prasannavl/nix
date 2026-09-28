# Abird Host Manager Fleet Dependency Audit And Reduction Plan (2026-09)

## Purpose

`abird-host-manager fleet` is the native Rust port of the Bash/Python `nixbot`
workflow. The package still carries the whole Bash runtime tool set inherited
from `pkgs/tools/nixbot/default.nix`. This note is the pre-cutover audit of that
external dependency surface: what the Rust code actually invokes, what is only a
legacy `REQUIRED_PROGRAMS` entry, what can become a Rust crate or in-binary
logic, what is hard to remove, and what must survive so a host can still be
bootstrapped before `abird-host-manager` exists on it.

The audit is read-only. No implementation change is made by this note.

## How external dependencies are resolved

There are three independent resolution surfaces. They must not be conflated:

1. **Controller-local PATH.** `pkgs/tools/abird-host-manager/default.nix`
   defines `fleetRuntimeInputs` (`age`, `cloudflared`, `coreutils`, `findutils`,
   `gawk`, `git`, `jq`, `getent`, `inetutils`, `iproute2`, `nix`, `openssh`,
   `opentofu`, `procps`, `util-linux`) and wraps the binary with
   `--prefix PATH`. This PATH is what applies when the manager itself spawns a
   process locally.
2. **Remote/target commands.** `fleet/host_runtime.rs` sends scripts over SSH as
   `ssh -- TARGET /run/current-system/sw/bin/bash` and exports
   `PATH=/run/wrappers/bin:/run/current-system/sw/bin`. Bare command names in
   remote scripts therefore resolve against the **target's own system profile**,
   not the controller wrapper. This is the surface that matters for bootstrap.
3. **Embedded Bash scripts.** `fleet/deploy.rs` (pre-switch, generation
   admission, candidate lease), `fleet/health_runtime.rs` (`HEALTH_COLLECTOR`,
   failure diagnostics), `fleet/build_runtime.rs` (builder GC lease), and
   `fleet/native.rs` (bootstrap key/age install) embed shell that runs either on
   the target (2) or locally (1). These are the real hidden dependencies.

`fleet/maintenance.rs` `REQUIRED_PROGRAMS` and the `deps`/`check-deps` actions
only describe surface 1 today and are already stale.

## What NixOS guarantees on every target

`nixos/modules/config/system-path.nix` `corePackageNames` always places these in
`/run/current-system/sw/bin` (verified on a real built LXC closure): `bash`,
`coreutils-full`, `findutils`, `gawk` (`awk`), `getent`, `gnugrep`, `gnused`,
`gnutar`, `procps`, `util-linux` (`flock`, `setpriv`, `timeout`), `curl`,
`diffutils`. `defaultPackageNames` adds `perl`, `rsync`, `strace`.

So a bare NixOS target already has `awk`, `getent`, `setpriv`, `flock`,
`timeout`, `readlink`, `base64`, `id`, `sort`, `cut`, `grep`, `sed`, `find`,
`ps`, `tar`. It does **not** guarantee: `jq`, `iproute2` (`ip`), `hostname`
(`inetutils`), `podman`, `age`, `tofu`, `cloudflared`. In practice targets also
carry `git`, `nix`, `ssh`, `ssh-keygen` (present in the sampled closures).

This means most `fleetRuntimeInputs` entries are redundant for remote execution
and can only be dropped from the controller wrapper after the controller-local
callers below are replaced.

## Inventory (fleet + the manager code it drives)

| Program                                                      | Where invoked                                                                                                    | Surface           | Finding                                                                  | Action                                                     |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------- |
| `nix`                                                        | `programs/nix.rs`, `fleet/{build,deploy,host_runtime,build_lease,terraform_runtime,native}.rs`                   | controller/target | Essential engine (`eval`, `build`, `copy`, `add-root`, `nix-store`)      | Keep                                                       |
| `git`                                                        | `fleet/repository.rs`, `fleet/runtime.rs`, `fleet/native.rs`, `fleet/terraform_runtime.rs`, `agent_adapter.rs`   | controller        | Clone/fetch/worktree/commit/push/merge-base/ls-files                     | Keep (hard); `gix` is a long-term option                   |
| `ssh`                                                        | `fleet/host_runtime.rs`, `agent_adapter.rs`, `fleet/ci_runtime.rs`                                               | controller        | Transport, ProxyCommand, agent forwarding, ControlMaster, forced command | Keep (hard); `russh` is a long-term option                 |
| `ssh-keygen`                                                 | `fleet/native.rs:1565` (`-y`), `:3297` (`-lf`)                                                                   | controller        | Derive public key and fingerprint only                                   | Replace with `ssh-key` crate                               |
| `ssh-keyscan`                                                | `fleet/native.rs`, `fleet/runtime.rs:194`, `fleet/ci_runtime.rs`                                                 | controller        | Initial known-hosts discovery                                            | Replace with `ssh-key`-based scan, or keep                 |
| `age`                                                        | `programs/age.rs`, `ssh_runtime.rs`, `fleet/ci_runtime.rs`, `fleet/terraform_runtime.rs`, `fleet/native.rs:1899` | controller        | Decrypt `.age` SSH/tfvar identities                                      | Replace with `age` crate (single decrypt helper)           |
| `tofu`                                                       | `fleet/terraform.rs:708`, `fleet/terraform_runtime.rs`                                                           | controller        | Actual OpenTofu effect for `fleet terraform`/`fleet tofu`                | Keep; consider a separate optional output                  |
| `cloudflared`                                                | Only as a user `proxy_command` string                                                                            | controller        | Never invoked directly; `ssh` needs it on PATH when configured           | Make optional/user-provided                                |
| `hostname`                                                   | `fleet/native.rs:1812`                                                                                           | controller        | Self-target alias detection                                              | Replace with `libc`/`rustix` `gethostname`                 |
| `ip`                                                         | `fleet/native.rs:1827`                                                                                           | controller        | Self-target address detection                                            | Replace with `getifaddrs`                                  |
| `getent`                                                     | `fleet/native.rs:1838`, target scripts                                                                           | controller/target | `ahosts` resolution; also NixOS core                                     | Replace local call with `getaddrinfo`; target copy is core |
| `id`                                                         | `fleet/native.rs:1848-1849`, target scripts                                                                      | controller/target | `-u`/`-un`; also NixOS core                                              | Replace local call with `libc`; target copy is core        |
| `env`                                                        | `fleet/native.rs:3805` (`with_nix_sshopts`)                                                                      | controller        | `env NIX_SSHOPTS=… nix …` wrapper                                        | Set `Command::env` instead                                 |
| `timeout`                                                    | `fleet/host_runtime.rs:1160` (`run_bounded_read`)                                                                | controller        | Local bounded read wrapper                                               | Implement an in-process deadline                           |
| `readlink`                                                   | `fleet/deploy.rs:161` snapshot (`-f /run/current-system`)                                                        | target            | NixOS core                                                               | Keep                                                       |
| `bash`                                                       | pre-switch, admission, lease, health scripts                                                                     | target            | NixOS core                                                               | Keep                                                       |
| `awk`/`gawk`                                                 | `fleet/deploy.rs` pre-switch, `fleet/health_runtime.rs`                                                          | target            | NixOS core                                                               | Keep; optionally rewrite for clarity                       |
| `jq`                                                         | `fleet/health_runtime.rs:893` `HEALTH_COLLECTOR`                                                                 | target            | **Not NixOS core**; silently drops held user units when absent           | Move the JSON parse into Rust; then drop                   |
| systemctl / systemd-run / switch-to-configuration / loginctl | activation, admission, pre-switch, health                                                                        | target            | Target interfaces                                                        | Keep                                                       |
| `podman` / `podman-composectl`                               | `fleet/host_runtime.rs:2039`, health                                                                             | target            | Host-dependent runtime check                                             | Keep                                                       |
| `nix-store`                                                  | `fleet/deploy.rs` candidate lease                                                                                | target            | Nix                                                                      | Keep                                                       |
| `abird-host-agent`                                           | `fleet/host_runtime.rs:2020`                                                                                     | target            | Once the host is deployed                                                | Keep                                                       |
| `nproc`, `pgrep`, `scp`, `stty`                              | `fleet/maintenance.rs` only                                                                                      | controller        | No production caller                                                     | Drop from `REQUIRED_PROGRAMS`                              |
| `find` (findutils)                                           | `fleet/repository.rs:7592` test fixture only                                                                     | n/a               | No production caller                                                     | Drop                                                       |
| `ps` (procps)                                                | only inside `podman ps`                                                                                          | target            | No direct caller                                                         | Drop from wrapper                                          |

Also invoked over SSH and owned by the target: `/run/current-system/sw/bin/nix`
(`fleet/host_runtime.rs:2249,2270`), `systemctl` (`:2006,2009`), and `podman`
(`:2039`). These are effect interfaces, not controller dependencies.

## Reduction plan

### Tier 0 — zero-risk cleanup

- Replace `REQUIRED_PROGRAMS` with the real controller-local set and have it
  cover only what survives Tier 1/2. Update `tests/fleet_binary.rs:282` and
  `tests/fleet_maintenance.rs`.
- Drop `procps` and `findutils` from `fleetRuntimeInputs` now: no production
  caller, and both are NixOS core on the controller anyway.
- Stop maintaining two identical runtime lists: `pkgs/tools/nixbot/default.nix`
  `runtimeInputs` and `pkgs/tools/abird-host-manager/default.nix`
  `fleetRuntimeInputs` must converge at cutover, ideally from one Nix binding.

### Tier 1 — easy in-binary replacements (controller only)

- `hostname` -> `libc::gethostname` / `rustix::system::uname().nodename()`.
- `id -u`/`id -un` -> `libc::geteuid` and `getpwuid`.
- `getent ahosts` -> `std::net::ToSocketAddrs` / `getaddrinfo`.
- `ip -o addr show up` -> `getifaddrs` (via `libc` or `nix` crate).
- `env NIX_SSHOPTS=…` -> `CommandSpec`/`ProcessRequest` environment.
- `timeout` -> an in-process deadline on `run_process`, reusing the existing
  process-group kill path.

After these land, `inetutils`, `iproute2`, `coreutils`, `util-linux`, and
`getent` can leave the controller wrapper (all are also NixOS core, so this is
mostly a closure-size and honesty win).

### Tier 2 — crate-backed replacements

- `age` -> `age` crate decrypt helper (RustCrypto). One shared helper replaces
  `programs/age.rs`, `SshRuntime::resolve_identity`, the CI materializer, the
  Terraform decryptor, and `materialize_declared_key`. Verify SSH-ed25519
  identities, passphrase handling, and error/redaction parity before removing
  the `age` binary from the wrapper.
- `ssh-keygen -y` / `-lf` -> `ssh-key` public-key/fingerprint parsing.
- `ssh-keyscan` -> optional `ssh-key`-based scan; low value, so keep if the
  library path is not clearly safer.
- `jq` in `HEALTH_COLLECTOR` -> parse the agent `hold list` JSON in Rust and
  pass held user units into the collector as arguments. This removes the only
  non-core target tool from a production remote script.

### Tier 3 — hard / deliberately kept

- `nix`: the engine. No realistic pure-Rust replacement.
- `git`: `gix` could cover clone/fetch/cat-file/rev-parse, but push, worktrees,
  SSH transport, hooks, and exact error semantics make this a project of its
  own. Defer.
- `ssh`: `russh` could replace OpenSSH, but ProxyCommand/`cloudflared`, agent
  forwarding, ControlMaster, known-hosts, and forced-command semantics are
  security-critical. Defer.
- `tofu`: the actual effect for Terraform commands. Keep, optionally as a
  separate package output so plain deploy/build hosts do not pull it.
- `cloudflared`: keep only as an optional/config-selected input.
- Target interfaces (`systemctl`, `switch-to-configuration`, `podman`,
  `nix-store`, `abird-host-agent`, `podman-composectl`): keep.

## Bootstrap safety

The bootstrap boundary is "a host that does not yet have a `nixbot`/
`abird-host-manager` closure". The first deploy to such a host performs only:

1. `snapshot_command` (`readlink -f /run/current-system`) — core.
2. `generation_admission_command` and `pre_switch_preparation_command` scripts —
   bash, `awk`, `systemctl`, `loginctl`, `setpriv`, `id`, `sort` — all core.
3. activation via the candidate generation's `switch-to-configuration` — core.
4. candidate GC lease — bash, `nix-store`, `readlink`, `mkdir`, `rm` — core.
5. health collection — currently also needs `jq` on the target.

Rules that follow from this:

- No pre-activation remote script may depend on a manager-only tool (`age`,
  `git`, `tofu`, `jq`). Today only step 5 uses `jq`, and it degrades silently
  rather than failing, so removing it is the single most important bootstrap
  fix.
- `fleetRuntimeInputs` reduction is controller-local and therefore
  bootstrap-safe, but each wrapper entry may only be removed **after** the
  corresponding Rust replacement lands and its caller no longer spawns the
  binary. Removing `coreutils`/`util-linux` from the wrapper without landing
  `timeout`/`env`/`awk` fixes would break local self-target execution.
- `check-bootstrap` uses `ssh-keygen` locally plus the target's forced-command
  `nixbot`. Keep `ssh-keygen` (or fully land the `ssh-key` replacement) until
  the forced-command cutover.
- When the controller is itself the target (`local_self_target`), the "target
  core" is the controller system, which still provides the core packages — so
  the same guarantee holds.

## Proposed final controller wrapper

After Tiers 0-2 and with Tier 3 kept wrapped, `fleetRuntimeInputs` becomes
`cloudflared`, `git`, `nix`, `openssh`, `opentofu`. `age` drops when the `age`
crate lands and `ssh-keygen`/`ssh-keyscan` become native under WP3b; `openssh`
stays solely for `ssh`. Everything else moves to Rust logic or is NixOS core.

## Implementation plan: Tiers 0-2

### Locked scope

- Tier 0, Tier 1, and Tier 2 land. Tier 3 stays wrapped.
- Revised Tier 2: `age` and target-side `jq` remove a package; in-scope **WP3b**
  replaces `ssh-keygen`/`ssh-keyscan` with native Rust (removes subprocess
  calls, not the `openssh` package). `ssh` is not replaceable in this effort.
- The active Bash `nixbot` at `pkgs/tools/nixbot/default.nix` keeps its full
  `runtimeInputs` until the explicit cutover. Only `abird-host-manager` shrinks
  now.

### Work package 1 — dependency metadata cleanup (Tier 0)

Files:

- `pkgs/tools/abird-host-manager/default.nix`
- `pkgs/tools/abird-host-manager/src/fleet/maintenance.rs`
- `pkgs/tools/abird-host-manager/tests/fleet_maintenance.rs`
- `pkgs/tools/abird-host-manager/tests/fleet_binary.rs`

Changes:

1. Drop `procps` and `findutils` from `fleetRuntimeInputs` (no production
   caller; both are NixOS core on the controller anyway).
2. Narrow `REQUIRED_PROGRAMS` to invoked, non-core controller binaries for the
   current code: `age`, `git`, `nix`, `ssh`, `ssh-keygen`, `ssh-keyscan`,
   `tofu`. Remove `cloudflared` (conditional `proxy_command` only), `jq`,
   `getent`, `nproc`, `pgrep`, `scp`, `stty`, `timeout`.
3. Update `fleet_maintenance.rs` (the fixture special-cases `age`/`git`/`nix`)
   and let `fleet_binary.rs` continue to enumerate `REQUIRED_PROGRAMS`
   generically; its `tofu` removal assertion still holds.

Validation: `cargo test -p abird-host-manager`, `fleet check-deps` under the
wrapped PATH, and `nix path-info -S` before/after.

### Work package 2 — controller-local in-binary replacements (Tier 1)

Files:

- `pkgs/tools/abird-host-manager/src/fleet/native.rs`
- `pkgs/tools/abird-host-manager/src/fleet/host_runtime.rs`
- new `pkgs/tools/abird-host-manager/src/fleet/system_identity.rs` (or
  `programs/host.rs`) for the libc helpers
- `pkgs/tools/abird-host-manager/default.nix`

Changes:

1. `NativeFleetEffects::self_target_evidence` (`native.rs:1800-1860`): replace
   the four `run_output` shell-outs with libc helpers.
   - `local_host_aliases()`: `gethostname` nodename, its short form, and the
     canonical FQDN via `getaddrinfo(AI_CANONNAME)`. Replaces `hostname`,
     `hostname -s`, `hostname -f`.
   - `local_ip_addresses()`: `getifaddrs` walk collecting `AF_INET`/`AF_INET6`
     addresses. Replaces `ip -o addr show up`.
   - `resolve_peer_addresses(target)`: `ToSocketAddrs`/`getaddrinfo`. Replaces
     `getent ahosts`.
   - `effective_uid()` / `current_user()`: `geteuid` + `getpwuid_r`. Replaces
     `id -u` and `id -un`.
2. `with_nix_sshopts` (`native.rs:3796`): stop wrapping in `env`. Return the
   command plus an environment vector and add `execute_local_command_with_env`
   on `HostRuntime`, or extend `CommandSpec` with an environment field. Preserve
   `NIX_SSHOPTS` exactly.
3. `run_bounded_read` (`host_runtime.rs:1147`): replace the external
   `timeout
   --foreground --signal=TERM --kill-after=5s Ns` wrapper with an
   in-process deadline on the child process group (SIGTERM, then SIGKILL after
   5s, status 124 on expiry). Reuse the existing `process_group(0)` and
   cancellation path in `run_process`.
4. Remove `coreutils`, `getent`, `inetutils`, `iproute2`, and `util-linux` from
   `fleetRuntimeInputs` once 1-3 are green.
5. Update `pkgs/tools/abird-host-manager/README.md:314` — the sentence claiming
   the package "explicitly carries the hostname and address-discovery tools" is
   no longer true after 1.

Risks:

- `--foreground` timeout parity for activation/observer streams: the deadline
  must not kill the SSH control master or unrelated processes. Bound the kill to
  the spawned child's process group only.
- `getifaddrs`/`getaddrinfo` are `unsafe` libc; keep them in one small module
  with unit-tested pure parsing helpers. Prefer `libc` (already a dependency)
  over adding the `nix` crate, to avoid lock/vendor churn.

Validation: unit tests for alias/short/address parsing; a `run_bounded_read`
test that a `sleep` deadline returns timeout without leaking the child; a
`with_nix_sshopts` test asserting environment delivery and unchanged argv;
existing `native`/`deploy` tests.

### Work package 3 — `age` crate (Tier 2a)

Files:

- root `Cargo.toml` / `pkgs/tools/abird-host-manager/Cargo.toml` / `Cargo.lock`
- `pkgs/tools/abird-host-manager/src/programs/age.rs`
- `pkgs/tools/abird-host-manager/src/ssh_runtime.rs`
- `pkgs/tools/abird-host-manager/src/fleet/ci_runtime.rs`
- `pkgs/tools/abird-host-manager/src/fleet/terraform_runtime.rs`
- `pkgs/tools/abird-host-manager/src/fleet/native.rs`
- `pkgs/tools/abird-host-manager/default.nix`

Changes:

1. Add `age` (RustCrypto) with the `ssh` feature to workspace and package
   dependencies; refresh `Cargo.lock`.
2. Replace the `Age` exec type with a decryptor that parses each identity as
   `age::x25519::Identity` or `age::ssh::Identity` and decrypts in-process. One
   helper serves all five call sites: `programs/age.rs`, `SshRuntime`,
   `AgeOrFileCredentialMaterializer`, `AgeCommandDecryptor`, and
   `materialize_declared_key`.
3. Preserve the `ABIRD_HOST_MANAGER_AGE` escape hatch: when set, keep the
   external-CLI path (`External(PathBuf)`); otherwise use the in-process path.
   This keeps plugin-recipient support and operator override without a hard
   dependency.
4. Drop `age` from `fleetRuntimeInputs` and `REQUIRED_PROGRAMS`; remove the
   `ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM` compile-time default once no caller
   needs it.
5. Preserve each caller's destination permissions (`0600`/`0440`), identity
   ordering, and error wording where tests assert it.

Risks:

- The `age` crate does not support `age-plugin-*` recipients; documented as the
  reason the external override stays.
- Passphrase-protected SSH identities are non-interactive today; keep failing
  the same way rather than adding a prompt.
- New transitive crates change the vendored closure; verify the offline Crane
  build still resolves from `Cargo.lock`.

Validation: in-process decrypt round-trip (encrypt with the crate in-test to a
generated x25519 recipient), SSH-identity decrypt fixture, external-override
fixture, and the existing `ssh_runtime`/`terraform_runtime`/`ci_runtime` tests.

### Work package 3b — native `ssh-keygen` + `ssh-keyscan` (Tier 2a', in scope)

Goal: stop invoking the `ssh-keygen` and `ssh-keyscan` subcommands. `openssh`
stays wrapped because `ssh` itself remains (see the feasibility note); this is a
behavior/dependency-honesty change, not a closure reduction.

**3b.1 `ssh-keygen` -> `ssh-key`**

- Add `ssh-key` to the workspace and package dependencies.
- `fleet/native.rs:1565` (`ssh-keygen -y`): parse `PrivateKey::from_openssh`,
  derive `public_key()`, render with `to_openssh()`.
- `fleet/native.rs:3297` (`ssh-keygen -lf`): use
  `public_key().fingerprint(HashAlg::Sha256)` directly and drop the stdout
  field-1 parsing.
- Encrypted private keys stay a non-interactive failure, matching today.
- Tests: ed25519 and RSA private-key fixtures; derive + fingerprint parity.

**3b.2 `ssh-keyscan` -> native host-key scanner**

- New `programs/ssh_scan.rs` exposing
  `scan_host_keys(host, port, timeout, preference) -> Vec<HostKey>`.
- Minimal synchronous SSH transport, unencrypted KEX only:
  1. TCP connect with the caller's timeout.
  2. Version-banner exchange and `SSH_MSG_KEXINIT`.
  3. Offer `curve25519-sha256` plus a host-key-algorithm list (`ssh-ed25519`,
     `rsa-sha2-512`, `rsa-sha2-256`, `ecdsa-*`); prefer `ssh-ed25519` first,
     then any, matching the current two-pass behavior.
  4. Send `SSH_MSG_KEX_ECDH_INIT` with 32 random bytes (no valid keypair is
     needed because the reply is only read, not verified — the same trust model
     as `ssh-keyscan`).
  5. Read `SSH_MSG_KEX_ECDH_REPLY` (type 31), extract the `K_S` host-key blob,
     and parse it with `ssh-key`.
- Dependencies: `ssh-key` (already added in 3b.1) and `rand` (already in the
  workspace). No `tokio`, no `russh`.
- Known-hosts formatting: `host keytype base64` or `[host]:port keytype base64`.
  Hashing (`ssh-keyscan -H`) is dropped because these files are private `0600`
  and short-lived; record the behavior change.
- Callers switch to the scanner: `native.rs::prepare_known_hosts` (`:1962`),
  `runtime.rs::scan_repository_host_key` (`:187`), and
  `ci_runtime.rs::execute_ci_trigger` (`:604`). Remove `CiPrograms.ssh_keyscan`
  and the corresponding `CiPrograms::new` argument.
- Timeouts reuse `ssh_connect_timeout_seconds` and `keyscan_timeout_seconds`.
- Tests: a hermetic fake SSH server that completes the banner/KEXINIT/ECDH
  exchange with a fixed host key; packet framing and `KEX_ECDH_REPLY` parser
  tests; known-hosts formatting including IPv6 and non-default ports.

**Lower-risk alternative for 3b.2** (if we accept keeping one subprocess): reuse
the already-wrapped `ssh` with `StrictHostKeyChecking=accept-new` and an
isolated `UserKnownHostsFile`, then read the recorded entry back. That removes
the `ssh-keyscan` binary with ~50 lines and no protocol code, at the cost of a
full handshake/auth attempt. Plan the native scanner as primary; fall back if
KEX compatibility proves fragile.

#### 3b.3 metadata

- Remove `ssh-keygen` and `ssh-keyscan` from `REQUIRED_PROGRAMS`.
- `openssh` stays in `fleetRuntimeInputs` for `ssh`.

Risks: SSH framing/KEX compatibility and packet ordering; keep the scanner
isolated, read-only, and covered by a live test against a real sshd. The
`-H`/multi-algorithm behavior difference must be documented.

### Work package 4 — remove target-side `jq` from health (Tier 2b)

Files:

- `pkgs/tools/abird-host-manager/src/fleet/health_runtime.rs`
- `pkgs/tools/abird-host-manager/src/fleet/host_runtime.rs` (probe fixtures if
  touched)
- `pkgs/tools/abird-host-manager/default.nix`

Design: keep one collector round-trip and move hold logic to Rust.

1. Remove `held_tsv`, the `jq` pipeline, every `--exclude-unit`, and the
   `role=held` unit query from `HEALTH_COLLECTOR`. Enumerate users from
   `/etc/systemd/user/*-managed.target` only, and emit all declared units as
   `expected`.
2. In `check_managed_health_with_progress`/`classify_observation`, use the
   already-parsed `hold_response` (`holds_by_user`) to:
   - reclassify matching `expected` unit snapshots as `held` (repopulating
     `user.held` for transitional detection), and
   - add held-only users (holds with no managed target) to the observation.
3. Keep emitting `hold-response`; the manager still validates it with
   `validate_durable_holds`.
4. Remove `jq` from `fleetRuntimeInputs` (already gone from `REQUIRED_PROGRAMS`
   in WP1) and assert no embedded script references it.

Fallback if parity proves hard: run `abird-host-agent --json hold list` as a
separate bounded remote command, parse it in Rust, and pass the held user/unit
pairs into `managed_health_command` as quoted arguments. This trades an extra
round-trip for a smaller collector diff.

Risks:

- Held-unit parity is the main risk; cover it with collector-output fixtures
  that include held users and held units in both `expected` and `runtime`.
- `podman-composectl expected-units` must return declared units without
  requiring `--exclude-unit`; verify on a host with an active hold.

Validation: `health_runtime` unit tests for held/system/user classification, a
fixture with no `jq` on PATH, and one live deploy with an open user-service
hold.

### Work package 5 — final wrapper + docs (closeout)

1. Set `fleetRuntimeInputs` to `cloudflared`, `git`, `nix`, `openssh`,
   `opentofu`; keep `nativeCheckInputs` unchanged (test-only).
2. Finalize `REQUIRED_PROGRAMS` to `git`, `nix`, `ssh`, `tofu` (WP3b removes
   `ssh-keygen`/`ssh-keyscan`).
3. Update `pkgs/tools/abird-host-manager/README.md` self-deployment sentence and
   this note's inventory status.
4. Record the `nixbot`/`abird-host-manager` runtime-input divergence as a
   cutover task, not a permanent state.

### Ordering and gates

1. WP1 lands alone (metadata only).
2. WP2 lands per replacement, dropping each wrapper input only after its caller
   is green.
3. WP3 and WP4 are independent after WP1; WP4 is the highest-value target fix
   and should land before any target cutover.
4. WP5 closes out once Tier 3 inputs are confirmed kept.

## Feasibility note: dropping `openssh`

`ssh-keygen` and `ssh-keyscan` can be eliminated as _invocations_ with the
`ssh-key` crate. That is cheap (WP3b), but it does not remove the `openssh`
package, because `ssh` remains. A closure reduction only happens if `ssh` itself
goes.

Dropping `ssh` is not a dependency-reduction task; it is an OpenSSH-compatible
client rewrite. The external `ssh` CLI is a hard contract for four consumers
that the manager does not own:

1. **Nix `ssh-ng://` stores.** `fleet/host_runtime.rs:1542` builds
   `ssh-ng://user@host` and `:1553` exports `NIX_SSHOPTS`. Nix spawns `ssh` from
   PATH for every `nix copy`/remote build; the manager cannot intercept that
   transport.
2. **Git.** `repository.rs:3902` sets `GIT_SSH_COMMAND`, and the repository
   config generates `GIT_SSH_COMMAND`/`GIT_SSH` ssh command strings
   (`repository.rs:87-99`). Git spawns the external program it is given.
3. **Target-side transfers.** `agent_adapter.rs:267` propagates
   `/run/current-system/sw/bin/ssh` as the target agent's `ssh_program`; the
   target runs it for `rsync -e` (`abird-host-agent/src/transfer.rs:1463`),
   tar-over-ssh (`:1446`), and the broker lane with agent forwarding (`-A`,
   `SSH_AUTH_SOCK`) in `abird-host-agent/src/broker.rs:130,248`. A replacement
   shim would have to be shipped in the target agent closure, which is a
   bootstrap-visible change.
4. **ProxyCommand / interactive.** `cloudflared access ssh` is invoked by `ssh`
   (`agent_adapter.rs:1389,1399`), `host ssh`/`host exec` are byte-transparent
   PTY passthroughs, and `ControlMaster`/`ControlPersist`, `ForwardAgent`,
   `StrictHostKeyChecking=accept-new`, and `-W` jump semantics are all OpenSSH
   behavior.

A pure-Rust client (`russh` + `ssh-key`) would need to reproduce mux,
agent-forwarding, ProxyCommand, host-key policy, PTY/signal handling, and an
`ssh`-compatible shim that Nix/git/rsync can spawn. That is security-critical
and materially larger than this effort. It also buys little: OpenSSH is already
present in every sampled target system profile
(`/run/current-system/sw/bin/ssh`, `ssh-keygen`, `ssh-keyscan`), so the only
theoretical saving is the controller wrapper entry.

Recommendation: keep `openssh` wrapped (Tier 3) and replace `ssh-keygen`/
`ssh-keyscan` natively under WP3b. Replacing `ssh` itself should be revisited
only as a standalone "native SSH transport" project.

## Validation

- `cargo test -p abird-host-manager` (fleet_binary, fleet_maintenance, deploy,
  health_runtime, native, terraform_runtime suites).
- Build `.#abird-host-manager` and run `fleet check-deps` against the reduced
  `REQUIRED_PROGRAMS`.
- `fleet run --dry` against a multi-host selection; assert the exact generated
  remote command set is unchanged.
- One real deploy on a spare host, and one deploy to a host whose systemPackages
  lack `jq`, to prove the collector no longer needs it.
- Confirm `nix path-info -S` closure shrink for the package after each tier.

## Decisions and remaining questions

Decided:

- Tiers 0-2 land; Tier 3 (`nix`, `git`, `ssh`/`openssh`, `tofu`, `cloudflared`)
  stays wrapped.
- `ssh` stays wrapped: the external OpenSSH CLI is a hard contract for Nix
  `ssh-ng` stores, git, target-side `rsync`/broker transfers, and interactive
  passthrough (see the feasibility note).
- `ssh-keygen`/`ssh-keyscan` are replaced natively in WP3b; that removes the
  subprocess calls but not the `openssh` package, because `ssh` stays.
- `cloudflared` and `tofu` stay as wrapped, always-present inputs; a separate
  Terraform-only output is deferred.

Remaining questions:

- Keep the external `ABIRD_HOST_MANAGER_AGE` override for `age-plugin-*`
  recipients, or accept the crate-only path?
- When to schedule `gix`/`russh` work; both remain out of scope.
