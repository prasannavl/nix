# Nixbot Key Rotation

## Scope

Canonical SSH deploy-key rotation policy for `nixbot`.

## Durable rules

- Default to overlap rotation.
- `users/userdata.nix` may carry multiple active deploy and bastion ingress
  public keys during the overlap window.
- `data/secrets/default.nix` must include recipients for every active key in
  that overlap set.
- Bastion private-key cutover and downstream host trust rollout must move
  together.
- If some hosts still need the legacy key, use temporary per-host `key` and
  `bootstrapKey` overrides in `hosts/nixbot.nix`.
- Keep the legacy bastion-side private key available during the overlap window
  when downstream hosts still require it.

## Operator guardrails

- Never print private key material.
- Keep key generation and key execution as separate procedures.
- Execution remains confirmation-gated because it changes live trust state.

## Execution surface

- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`

## Source of truth files

- `users/userdata.nix`
- `hosts/nixbot.nix`
- `lib/nixbot/default.nix`
- `lib/nixbot/bastion.nix`
- `data/secrets/default.nix`

## Provenance

- This note replaces the earlier dated key-rotation policy and playbook-summary
  note.
