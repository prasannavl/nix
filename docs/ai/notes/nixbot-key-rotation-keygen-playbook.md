# Nixbot Keygen Playbook

Date: 2026-02-26

## User Direction
- Add a second playbook for preparing key material before execution phases.

## Output
- Added `docs/ai/playbooks/nixbot-key-rotation-keygen.md` with:
  - mandatory per-step confirmation gating
  - key generation commands for new nixbot and bastion keys
  - fingerprint validation
  - deterministic age encryption using `data/secrets/default.nix` recipients
  - CI secret hand-off guidance
  - plaintext cleanup step
