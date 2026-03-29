# Lib Review Follow-up (2026-03)

## Context

Follow-up after review and fixes in `lib/incus.nix`, `lib/podman.nix`, and
`lib/systemd-user-manager.nix`.

The user clarified that `systemd-user-manager` starting inactive-but-startable
managed units is intended behavior, so the needed change there was to fix the
docs, not the code.

The user also pointed to a concrete `pvl-x2` generation for the boot failure
investigation:

- `/nix/store/iqhvpy03a21s0r1wc01g9h0amsg3qqk7-nixos-system-pvl-x2-25.11.20260323.4590696`

## Code Changes

- `lib/podman.nix`: `recreateTag` now arms the next managed start/restart to use
  `podman compose up --force-recreate`, while normal starts stay on the
  non-force path.
- `lib/podman.nix`: fixed the `systemd-notify --exec` separator in the managed
  start wrapper.
- `lib/incus.nix`: no longer masks real instance start failures.
- `docs/systemd-user-manager.md`: updated for the intended inactive-unit
  semantics.

## Provided Generation Root Cause

After narrowing the regression window again, the critical bad commit is
`307016b` (`Rewrite systemd-user-manager and podman reconciliation`), while
`2b1feee` still works.

The actual boot activation bug in `307016b` is in the generated
`system.activationScripts` shell, not in the later `multi-user.target`
reconciler unit.

`307016b` added three activation snippets:

- `systemdUserManagerIdentity`
- `systemdUserManagerPrune`
- `systemdUserManagerReconcilerRun`

Each snippet tries to skip non-`switch|test` actions with a shell branch like:

- `printf ...`
- `exit 0`

That is a shell control-flow bug. These snippets are pasted directly into the
top-level `/activate` script, so `exit 0` exits the entire activation script,
not just the individual snippet.

On the generated regressed host activation script, the first such early exit is
in `systemdUserManagerIdentity`:

- `/nix/store/iqhvpy03a21s0r1wc01g9h0amsg3qqk7-nixos-system-pvl-x2-25.11.20260323.4590696/activate`
  lines 539-552

That means a normal boot with `NIXOS_ACTION` unset or non-`switch|test` hits:

- `systemdUserManagerIdentity`
- prints the “skipped” message
- executes `exit 0`
- aborts the rest of `/activate`

So boot activation stops partway through the script and never reaches the later
activation snippets or the final `/run/current-system` update near the end of
`/activate`.

This is the root cause that actually fits the “boot activation failed / switch
root got stuck” symptom.

The later `systemd-user-manager` and Podman regressions are still real but
secondary:

- the new boot-time reconciler and `--machine=pvl@` fanout cause
  post-switch-root PAM/session failures
- the generated Podman start wrapper also had a malformed
  `systemd-notify --exec` handoff

But those happen later. The bug that directly broke boot activation in `307016b`
is the use of top-level `exit 0` in activation snippets that were supposed to be
“skipped”.

## Why It Looked Confusing

- Many Podman services still start successfully, so the system appears mostly
  up.
- But the activation-script `exit 0` bug happens before the later service-level
  failures, so the host can look like it died very early in boot.
- The same rewrite also introduced post-switch-root user-manager / Podman
  regressions, which added noise and made the diagnosis look more ambiguous than
  it really was.

## Evidence

- Recovery booted generation on `pvl-x2`:
  `/nix/store/lqnrjwclza20cv9bjsgc43ncjdl4s75m-nixos-system-pvl-x2-25.11.20260323.4590696`
- Regressed profile generation still present:
  `/nix/store/iqhvpy03a21s0r1wc01g9h0amsg3qqk7-nixos-system-pvl-x2-25.11.20260323.4590696`
- Generated failing activation script in `system-439`:
  `/nix/store/iqhvpy03a21s0r1wc01g9h0amsg3qqk7-nixos-system-pvl-x2-25.11.20260323.4590696/activate`
- In that script, `systemdUserManagerIdentity` contains a top-level `exit 0` at
  lines 545-552, before the rest of the activation script and before the final
  `/run/current-system` update.
- `307016b` source in `lib/systemd-user-manager.nix` contains the same pattern
  at the activation snippets around lines 937-959, 1054-1064, and 1108-1118 in
  the committed file.
- `journalctl -b -1` around `2026-03-29 11:34:51 +08` also shows the
  `system-439` switch itself triggering a large `systemd-stdio-bridge` / PAM
  failure storm, which is a separate later regression from the same rewrite.
