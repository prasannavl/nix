# Systemd User Manager Boot Deferral

## Context

`lib/systemd-user-manager.nix` originally ran its per-user reconciler
synchronously from `system.activationScripts` for every activation, including
boot activation. That made boot vulnerable to deploy-time user-manager actions
such as rootless Podman image pulls or restart waits.

That was only a partial fix until all module-owned activation scripts were
audited. The module also had prune and identity-refresh activation scripts that
still ran on boot and could fail activation independently of the reconciler
path.

This was acceptable for `switch`, where failing fast is useful, but it was the
wrong shape for boot. Boot should reach normal interactive and remote access
targets first, then reconcile managed user units later.

## Decision

Split the execution model by `NIXOS_ACTION`:

- `switch` and `test` keep the synchronous activation-hook path
- `boot` and other non-interactive activation modes skip all mutating
  `systemd-user-manager` activation-script work
- `dry-activate` runs preview logging for reconcile and skips prune and
  identity refresh entirely

Keep the per-user reconciler as a normal boot-time systemd unit wanted by
`multi-user.target`, ordered after and wanting `user@<uid>.service`.

Add a user target, `systemd-user-manager-ready.target`, that the reconciler
starts only after a successful apply. Boot-gated consumers can attach their
user services to that target instead of `default.target`.

## Outcome

- boot no longer waits synchronously for `systemd-user-manager` reconcile work
- a failed user-manager action no longer fails boot activation directly
- prune of removed managed units no longer blocks boot activation
- user-manager identity-refresh restarts no longer block boot activation
- boot still runs the reconciler automatically as part of the normal systemd
  target graph once the user manager is available
- boot-gated managed user services no longer race ahead of the reconciler in
  the user manager
- the ready-target gate does not deadlock boot because reconcile still starts
  managed user units directly and only uses the target for automatic pull-in
- deploy-time `switch` still shows reconciler progress inline and fails fast on
  reconcile errors

## Durable Rule

Treat this as a repo-level invariant for NixOS modules:

- boot activation must never be blocked by repo-owned mutable service logic
- `system.activationScripts` must not perform boot-time network pulls, reconcile
  loops, service-manager restarts, or cleanup that can fail
- any such work belongs in later normal systemd units, timers, or targets after
  userspace is available
