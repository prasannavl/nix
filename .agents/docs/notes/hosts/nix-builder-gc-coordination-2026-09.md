# Nix builder GC coordination

## Scope

Builder-role hosts import `lib/services/nix-builder-gc-coordination`. The role
is currently enabled by `hosts/pvl-x2/default.nix`, the Pvl controller, cache,
and remote builder.

The generic fleet GC policy remains in `lib/nix.nix`. The builder role does not
change its schedule or retention age.

## Lock contract

All coordinated operations lock the stable Nix state-directory inode:

```text
/nix/var/nix
```

Builds and one invocation-wide build lease take shared locks. Scheduled
`nix-gc.service` and host-agent `maintenance gc` take exclusive locks. Multiple
deployments may therefore share the builder while every supported GC entrypoint
waits until no deployment depends on its store paths.

The controller-owned inline protocol exposes two operations:

- `hold` acquires a shared lock, writes `READY`, and acknowledges each `PING`
  with `PONG`. EOF, process death, or 45 seconds without a heartbeat releases
  the lock through normal kernel file-descriptor ownership. The controller's
  15-second protocol heartbeat is internal and independent of optional build
  progress logging.
- `run <command> [args...]` acquires a shared lock and then replaces itself with
  the command. This independently protects every builder command even while an
  invocation lease is being recovered.

There are no profiles, generations, persistent GC roots, cleanup RPCs,
per-invocation lease files, or stale-root reapers.

## GC ownership

The scheduled NixOS GC script receives a short exclusive-lock preamble with
`lib.mkBefore`; the upstream-generated command and `nix.gc.options` remain
authoritative. The host-agent module accepts an absolute
`nixCollectGarbageProgram`; builders inject the exclusive-lock wrapper while
ordinary hosts retain the upstream `nix-collect-garbage` default.

Builder-role `min-free = 0` prevents daemon free-space GC from bypassing the
lock. Raw privileged calls such as `nix store gc` are outside this advisory
contract and must not be used during fleet builds.

## Admission and recovery

The role defaults `max-jobs = 1` and leaves `cores = 0`, admitting one
derivation with the builder's effective CPU set. Future builder hosts inherit
both admission and GC coordination by importing the role.

The controller records only a process-local lease epoch. If the invocation lease
is lost before a closure crosses the builder-dependency boundary, it reacquires
the lease and revalidates that exact path. Existing paths continue; missing
paths rebuild under the inline `run` protocol. It does not sweep old outputs,
create roots, or retain cleanup state. Lease loss after distribution is
irrelevant to activation and health checking.

## Generation-independent lease protocol

A lease-aware deploy cannot require the live builder generation to provide a
helper because deploying that generation itself requires a working builder. A
normal deploy must not require a separate builder bootstrap.

The lease protocol is therefore controller-owned in both Bash Nixbot and the
native Rust fleet runtime. The controller sends an inline Bash protocol over its
dedicated SSH session and uses the baseline NixOS `bash` and `flock`
executables. Both invocation-wide leases and individual remote realizations take
a shared advisory lock on `/nix/var/nix`, a stable directory inode available on
every usable Nix builder. Guarded scheduled and host-agent GC take the exclusive
side of the same lock.

No custom executable, pre-created lock file, target generation, or bootstrap
command is required. EOF, process death, heartbeat timeout, and reboot still
release the kernel-owned lease. Bash starts the lease before build-plan
evaluation, and transport loss retains the existing bounded reconnect contract.
Dry Bash deploys skip the live activation-unit wait.

## Recovering a cold fixed-output dependency

A deployed target can retain the exact final output required by an evaluated
closure after both the builder and target have lost an intermediate registry or
dependency-fetch output. Before repeating a fragile external transfer, check
whether a target still has the exact requested final store path. Export and
import only that evaluated path, and protect the builder-side import with the
shared `/nix/var/nix` lease. Never substitute a tag or an inferred equivalent
output.

Until the generation that enforces `max-jobs = 1` is active, pass `--max-jobs 1`
explicitly to manual recovery builds.
