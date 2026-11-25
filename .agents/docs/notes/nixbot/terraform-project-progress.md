# Fleet Terraform project progress

- Derive host-roster visibility from the workflow's phases. Terraform-only runs
  retain source and lock metadata, not the host tree.
- Reuse the fleet roster renderer and phase accounting for project rows. Project
  snapshots never enter host summaries or host timing totals.
- Advance rows before each actual subprocess: optional asset preparation, init,
  plan, apply. Keep provider output on the existing redacted log path; the
  dashboard does not parse it or infer resource-level completion.
- Skips, failures and interruption are distinct. A dry run has no apply step.
  Keep phase order, saved-plan application and workspace semantics unchanged.
