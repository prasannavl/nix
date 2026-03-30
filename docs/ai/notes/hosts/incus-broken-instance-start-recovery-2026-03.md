# Incus Broken Instance Start Recovery

## Context

After the JSON environment fix, `incus-pvl-vlab.service` on `pvl-x2` advanced
far enough to create the declared guest and attach its devices. A later run
still failed because the Incus instance record existed while the container
rootfs was missing on disk.

That left the helper in an awkward state:

- `incus info <name>` succeeded, so the helper no longer took the create path
- the stored `user.config-hash` already matched the declaration
- later runs only tried to start the broken instance and failed with:
  `Unable to resolve container rootfs ...`

## Decision

- Detect recoverable start failures that indicate a broken partial instance,
  currently:
  - `Unable to resolve container rootfs`
  - `Storage volume not found`
- On the first such failure in a given helper run:
  - log the error
  - force-delete the broken instance
  - loop back through the normal create path once

## Operational Effect

- A half-created managed Incus guest no longer gets stuck forever behind a
  matching `user.config-hash`.
- Recovery is bounded to one forced recreate attempt per helper run.
- The custom state volume remains separate from the container rootfs, so a
  recreate can recover the guest without discarding the intended persistent
  disk.
