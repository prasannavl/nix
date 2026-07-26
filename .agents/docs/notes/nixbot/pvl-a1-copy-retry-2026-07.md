# `pvl-a1` copy retry during the 2026-07-25 deploy

Run `FMoB7g` separated two failures that were interleaved in the parallel deploy
output:

- `pvl-a1` lost its SSH-backed Nix store stream while copying the built closure.
  The target journal recorded a Tailscale peer endpoint change at
  `01:04:53-01:04:54 +0800`, followed by the SSH session closing at `01:04:55`
  after receiving about 18.5 MB. Nixbot classified the resulting `Broken pipe`
  as transport loss and started copy attempt 2 at `01:04:57`.
- `pvl-l5` reached activation but exited with status 4 after graphical user-unit
  failures and a disconnected user D-Bus. Since its deploy mode was `optional`,
  this did not abort the required-host jobs in the same wave.

The `pvl-a1` retry did not submit activation twice. The retry boundary was
`run_remote_store_command_with_retry`, which replayed the content-addressed,
idempotent `nix copy` operation before `switch-to-configuration`. Nix printed
the full `copying 4058 paths...` plan again, which made the output resemble a
second deploy.

Live run artifacts confirmed there was one top-level nixbot process and one
successful snapshot per wave-zero host. During the copy retry, `pvl-a1` and
`pvl-x2` had active copy jobs but no activation markers. `pvl-l5` had an
activation result of 4; `/run/current-system` pointed at the attempted target
while `/nix/var/nix/profiles/system` still pointed at the pre-deploy snapshot,
preserving the rollback boundary.
