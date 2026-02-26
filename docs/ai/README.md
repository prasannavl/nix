# AI Docs Index

- `docs/ai/playbooks/nixbot-deploy.md`: Reconstruction spec for nixbot deployment architecture and bootstrap behavior.
- `docs/ai/playbooks/nixbot-key-rotation-execution.md`: Agent-executable phased key-rotation playbook with mandatory confirmation gates.
- `docs/ai/playbooks/nixbot-key-rotation-keygen.md`: Agent-executable key-generation and secret-packaging playbook for rotation prep.
- `docs/ai/notes/nixbot-bastion-key-model.md`: Final key-model decision (forced-command bastion key + regular nixbot key via default module).
- `docs/ai/notes/nixbot-deploy-bootstrap-flag.md`: Added `--bootstrap` option to force bootstrap deploy target path selection.
- `docs/ai/notes/nixbot-forced-command-bootstrap-check-bash-dash-error.md`: Root-cause fix for forced-command bootstrap checks that surfaced as `bash: --: invalid option`.
- `docs/ai/notes/nixbot-key-rotation-legacy-key-recovery.md`: Incident recovery for legacy-host lockout after bastion key cutover (restored overlap keys + temporary legacy key overrides).
- `docs/ai/notes/nixbot-key-rotation-sensitive-output-and-confirmation-policy.md`: Operator security constraints (no secret output) and confirmation-policy defaults for rotation.
- `docs/ai/notes/nixbot-key-rotation-overlap-and-bastion-cutover.md`: Key-list overlap implementation and bastion-first phased cutover runbook.
