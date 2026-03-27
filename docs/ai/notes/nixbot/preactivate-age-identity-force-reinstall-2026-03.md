# Preactivate Age Identity Force Reinstall

## Context

After reintroducing the Incus guest snapshot wait, `nixbot` progressed past the
nested-host snapshot race but then failed during activation-time agenix decrypt
on that same nested host.

Observed behavior:

- deploy logged
  `Skipping host age identity for <nested-incus-host>; matching key
  already present on target`
- agenix then reported `/var/lib/nixbot/.age/identity` missing during the switch
- the host-side filesystem after the failed deploy showed
  `/var/lib/nixbot/.age/identity` absent

That means the final pre-activation guard could still trust a stale checksum
result instead of forcing the identity back onto the target immediately before
`nixos-rebuild-ng`.

## Decision

Keep the earlier checksum-skip behavior for the initial deploy-context setup,
but force a real reinstall on the final pre-activation injection path.

## Operational Effect

- normal pre-deploy setup still avoids unnecessary rewrites
- the last injection before activation now overwrites the machine age identity
  unconditionally
- fresh Incus guests no longer depend on a potentially stale "already present"
  result right before agenix decrypts secrets
