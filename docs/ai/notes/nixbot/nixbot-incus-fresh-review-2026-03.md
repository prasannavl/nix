# Nixbot And Incus Fresh Review (2026-03)

## Scope

Fresh review of `pkgs/nixbot` and `lib/incus` focused on correctness,
regressions, and simplification opportunities.

## Findings

### High: parent readiness failures are swallowed

`pkgs/nixbot/nixbot.sh` captures `rc="$?"` immediately after an
`if
run_prepared_root_command ...; then ...; fi` block in
`run_named_prepared_root_command()`.

In Bash, `$?` after the `if` compound is the status of the `if` statement
itself, not the failed command inside it. When the readiness command fails, the
function records `0`, skips the reconnect retry path for transport exit `255`,
and returns success after printing a failure message.

That means parent readiness barriers can fail without aborting the deploy wave,
which defeats the Incus reconcile/settle guard introduced for child guests.

### Medium: Incus guest status lookup uses filtered list semantics instead of an exact lookup

`lib/incus.nix` uses `incus list "$name" --format json` in both reconcile and
settle helpers, then reads `.[0]`.

`incus list` is a filtered listing command, not an exact instance lookup. If
multiple instances match the filter, the helpers can read the wrong row and
misclassify a guest as running, missing, or stopped.

Use an exact per-instance query (`incus info <name>`,
`incus query
/1.0/instances/<name>`, or equivalent) instead of list filtering in
these paths.

### Low: nixbot package wrapper still depends on ambient coreutils/findutils before runtime re-exec

`pkgs/nixbot/default.nix` exposes a wrapper PATH with `age`, `git`, `jq`, `nix`,
`nixos-rebuild-ng`, `openssh`, and `opentofu`, but not `coreutils` or
`findutils`.

`pkgs/nixbot/nixbot.sh` calls `rm`, `mkdir`, `mktemp`, `find`, and `readlink`
before `ensure_runtime_ready()` finishes re-execing into the managed runtime.
That works on typical NixOS/user shells, but it means `nix run ./pkgs/nixbot` is
not actually self-contained under a minimal or sanitized PATH.

## Cleanup Opportunities

- `lib/incus.nix`: factor the repeated `--machine` selection parsing shared by
  `incus-machines-reconciler` and `incus-machines-settlement`.
- `pkgs/nixbot/flake.nix`: collapse the repeated `run/default/build` and
  `default/run` alias boilerplate with `inherit`.

## Resolution

- Fixed `run_named_prepared_root_command()` to capture the failing command exit
  status from the `else` branch, preserving retry-on-`255` and fail-fast parent
  readiness behavior.
- Switched Incus reconcile and settle status detection from filtered
  `incus list` calls to exact `incus query /1.0/instances/<name>` lookups.
- Added `coreutils` and `findutils` to `pkgs/nixbot/default.nix` so the wrapper
  has the base filesystem tools it uses before the managed runtime re-exec.
- Added a timeout and stale-lock recovery path for the shared repo-root lock so
  a dead process cannot leave `nixbot` spinning forever on `mkdir`.
- Stopped treating bootstrap-target SSH transport failure as proof that the
  bootstrap key is missing; `nixbot` now fails with an explicit reachability
  error instead of attempting a misleading reinjection.
- Added one shared bounded SSH transport retry policy for safe/idempotent remote
  operations such as connectivity probes, current-system reads, parent readiness
  commands, forced-command bootstrap checks, and remote file-value validation.
  Mutating deploy/install steps remain single-shot to avoid duplicate side
  effects.
- Added per-node SSH control-master sockets for direct primary/bootstrap
  contexts so repeated `ssh`, `scp`, bootstrap checks, and `nixos-rebuild-ng`
  target connections reuse the same transport instead of opening a fresh SSH
  session each time. Proxied hosts intentionally skip control-master reuse to
  avoid multiplexing failures through `ProxyCommand` chains.
