# Nixbot Host-Local Lock No-Block Race

## Incident

On 2026-08-25, most local nixbot actions failed with:

```text
mkdir: cannot create directory '/dev/shm/nixbot-host-local.lock.d': File exists
Failed to create nixbot host-local lock directory: /dev/shm/nixbot-host-local.lock.d
```

The path was a root-owned, mode-`0644`, empty regular file. The host-local lock
contract requires a persistent mode-`0755` directory that all principals open
read-only and lock by inode.

## Root Cause

Commit `870124a4` changed activation submission from attached
`systemd-run --wait --pipe` to detached `systemd-run --no-block` plus a retained
log observer. The activation lock helper still returned an unquoted compound
shell fragment:

```text
mkdir -p ... && flock -w ... <activation-runner>
```

That fragment was appended directly after the `systemd-run` options. The remote
outer shell parsed `&&`, so the transient unit received only `mkdir` as its
command. Because `--no-block` returns after admission, the outer shell ran
`flock` before the unit's `mkdir`; `flock` created a regular file at the lock
path, and the delayed `mkdir` then failed.

The journal established the ordering precisely: the root command was admitted at
`11:48:04.053`, the regular file was born at `11:48:04.076`, the transient
`mkdir` started at `11:48:04.077`, and it reported `File exists` at
`11:48:04.096`.

## Repair

`host_local_activation_lock_command` now returns one shell-quoted Bash argv. The
transient unit executes directory creation, a directory type check, and `flock`
within that Bash process. The outer shell can no longer split lock preparation
from the detached unit admission boundary.

The malformed live file was confirmed unlocked, replaced with the required
mode-`0755` directory, and successfully locked through a read-only file
descriptor as the local operator.

## Validation

- Direct regression coverage executes the generated lock wrapper and proves the
  target sees a directory.
- Switch and rollback command-shape tests require the quoted Bash wrapper to be
  the single command passed to `systemd-run`.
- The focused lock, switch, rollback, and parallel activation tests pass.
- The sandboxed nixbot helper test is the authoritative full-suite validation;
  ambient full-suite health tests can reach the live `/var/lib/abird-host-agent`
  and fail on its state-lock permissions.
