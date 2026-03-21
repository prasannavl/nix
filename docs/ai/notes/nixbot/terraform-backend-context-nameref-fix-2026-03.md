# Terraform backend context nameref fix

Date: 2026-03-21

- `scripts/nixbot.sh` regressed in `resolve_tf_backend_context_for_project`
  after the multi-provider Terraform refactor.
- The helper exposes output parameters via bash namerefs, and callers commonly
  pass variables named `backend_kind`, `backend_detail_1`, and
  `backend_detail_2`.
- The helper also declared a local scratch variable named `backend_kind`, which
  shadowed the caller target during nameref resolution.
- Result: callers kept an empty `backend_kind`, so `run_tf_action` logged only
  `Working dir:` and invoked `tofu init` without any `-backend-config=...`
  flags, causing Terraform/OpenTofu to prompt interactively for `bucket`.
- Durable rule: nameref helpers must avoid scratch locals that can collide with
  common caller output variable names, even if the nameref alias itself is
  uniquely named.
