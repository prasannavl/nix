# Nixbot Key Rotation: Sensitive Output and Confirmation Policy

Date: 2026-02-26

## User Interventions / Decisions

- Do not display or print any sensitive key material in agent output.
- GitHub secret `NIXBOT_BASTION_SSH_KEY` must be updated manually from local key
  path; no terminal key dump.
- Single-confirmation policy applies to keygen playbook only.
- Execution playbook keeps per-step confirmation behavior.

## Operational Default

- Preferred continuation flow is Mode A overlap rotation from current repo
  state.
