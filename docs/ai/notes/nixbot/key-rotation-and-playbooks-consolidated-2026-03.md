# Nixbot Key Rotation And Playbooks Consolidated Notes (2026-03)

## Scope

Canonical summary of the March 2026 `nixbot` rotation model, incident recovery,
operator constraints, and the playbooks created from that work.

## Rotation model

- `users/userdata.nix` uses list-based keys for overlap rotations:
  - `nixbot.sshKeys`
  - `nixbot.bastionSshKeys`
- Backward-compatible single-key aliases remain available.
- `lib/nixbot/default.nix` installs all normal deploy keys from `sshKeys`.
- `lib/nixbot/bastion.nix` installs all forced-command ingress keys from
  `bastionSshKeys`.
- `data/secrets/default.nix` includes all `nixbot` deploy-key recipients needed
  for the active overlap set.

## Operational model

- Preferred default is Mode A overlap rotation when all targets already trust
  the new deploy public key.
- Bastion-first single-pass cutover is supported through per-host
  `key`/`bootstrapKey` overrides in `hosts/nixbot.nix` for nodes that still need
  the legacy private key.
- Bastion keeps `/var/lib/nixbot/.ssh/id_ed25519_legacy` available so downstream
  SSH can still try the old key during overlap.
- Machine age identity rotation is normally single-step because deploy injects
  the host identity before activation.

## Incident recovery captured

- A rotation incident occurred when bastion switched to new deploy private key
  material before all downstream hosts trusted the new public key.
- Recovery steps were:
  - restore overlap public keys in `users/userdata.nix`
  - recover old private key as `data/secrets/nixbot/nixbot-legacy.key.age`
  - add recipient mapping for the legacy encrypted key
  - pin legacy hosts with temporary per-host `key` and `bootstrapKey` overrides
- The durable lesson is that bastion key cutover and target-host trust rollout
  must stay aligned, or legacy-node overrides must exist before bastion moves.

## Operator policy

- Agents must never print private key material.
- GitHub secret updates are manual and path-based.
- The key-generation playbook uses one upfront confirmation gate.
- The execution playbook requires confirmation before each execution step.

## Playbook outputs

- `docs/ai/playbooks/nixbot-key-rotation-keygen.md` is the reusable key
  preparation workflow.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md` is the reusable phased
  rotation workflow.
- Those playbooks are the execution surface; this note records the decisions and
  guardrails behind them.

## Superseded notes

- `docs/ai/notes/nixbot-key-rotation-execution-process.md`
- `docs/ai/notes/nixbot-key-rotation-keygen-playbook.md`
- `docs/ai/notes/nixbot-key-rotation-legacy-key-recovery.md`
- `docs/ai/notes/nixbot-key-rotation-overlap-and-bastion-cutover.md`
- `docs/ai/notes/nixbot-key-rotation-sensitive-output-and-confirmation-policy.md`
