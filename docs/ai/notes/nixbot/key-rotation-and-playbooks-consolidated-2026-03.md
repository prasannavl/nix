# Nixbot Key Rotation And Playbooks Consolidated Notes (2026-03)

## Scope

Canonical summary of the March 2026 `nixbot` key-rotation model, the failure
mode that mattered, and the operator guardrails that should stay in place.

## Durable model

- `users/userdata.nix` supports overlap rotation with list-based keys:
  - `nixbot.sshKeys`
  - `nixbot.bastionSshKeys`
- `lib/nixbot/default.nix` installs all normal deploy keys from `sshKeys`.
- `lib/nixbot/bastion.nix` installs all forced-command ingress keys from
  `bastionSshKeys`.
- `data/secrets/default.nix` must include recipients for every active deploy
  key in the overlap set.
- Machine age identity rotation is usually single-step because deploy injects
  the host identity before activation; SSH deploy-key rotation is the riskier
  path.

## Preferred operating pattern

- Default to overlap rotation when all targets already trust the new public key.
- Use per-host `key` and `bootstrapKey` overrides in `hosts/nixbot.nix` only
  for legacy nodes that still need the old private key after bastion starts
  carrying the new one.
- Keep `/var/lib/nixbot/.ssh/id_ed25519_legacy` available on bastion during the
  overlap window so downstream SSH can still fall back cleanly.

## Captured mistake

- The failure mode was cutting bastion over to new deploy private key material
  before all downstream hosts trusted the new public key.
- Recovery required restoring overlap public keys, reintroducing the legacy
  encrypted private key, wiring its recipients, and pinning legacy hosts to
  temporary key overrides.
- Durable rule: bastion private-key cutover and target-host trust rollout must
  move together, or legacy-host overrides must be prepared first.

## Operator constraints

- Never print private key material.
- GitHub secret updates remain manual and path-based.
- The key-generation playbook uses one confirmation gate up front.
- The execution playbook requires confirmation before each execution step.

## Execution surface

- `docs/ai/playbooks/nixbot-key-rotation-keygen.md` is the reusable key-prep
  workflow.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md` is the phased execution
  workflow.
- This note is policy and design memory; the playbooks are the step-by-step
  operational entrypoints.

## Superseded notes

- `docs/ai/notes/nixbot-key-rotation-execution-process.md`
- `docs/ai/notes/nixbot-key-rotation-keygen-playbook.md`
- `docs/ai/notes/nixbot-key-rotation-legacy-key-recovery.md`
- `docs/ai/notes/nixbot-key-rotation-overlap-and-bastion-cutover.md`
- `docs/ai/notes/nixbot-key-rotation-sensitive-output-and-confirmation-policy.md`
