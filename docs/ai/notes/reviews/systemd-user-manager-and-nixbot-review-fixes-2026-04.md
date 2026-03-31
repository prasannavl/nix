# systemd-user-manager and nixbot Review Fixes (2026-04)

## Scope

Follow-up fixes for review findings in:

- `lib/systemd-user-manager/helper.sh`
- `pkgs/nixbot/nixbot.sh`

## Findings Addressed

- `helper.sh` used `done < <(jq ...)` in metadata and preview loops, which let
  malformed or unreadable JSON degrade into a silent noop under Bash process
  substitution semantics.
- `nixbot`'s Terraform phase runner consumed `tf_project_dirs_for_phase()` via
  process substitution, which could turn a producer failure into a misleading
  partial run or a false `"No Terraform <phase> projects found"` message.
- The post-deploy `systemd-user-manager` report bypassed the normal combined
  host-log path, so report output was missing from per-host deploy logs and
  remote stderr could appear unprefixed.
- The remote dispatcher report filtered dispatcher journal lines through
  `grep 'dispatcher '`, which dropped dispatcher-side timeout and retry details.
- The post-deploy `systemd-user-manager` report helper still returned success
  after report-collection failures, which made "report unavailable" look the
  same as "no dispatcher ran".
- The report step still ran `prepare_deploy_context` outside the combined host
  logging wrapper, so context-setup diagnostics could bypass the per-host deploy
  log.

## Implementation

- Replaced the helper's `jq`-fed process-substitution loops with explicit
  capture-and-check steps before iterating, so metadata/preview parse failure is
  fatal instead of being treated as an empty dataset.
- Changed the Terraform phase runner to capture the full project-dir list before
  iterating, so any failure from `tf_project_dirs_for_phase()` aborts the phase.
- Routed the post-deploy dispatcher report through the same combined
  stdout/stderr host logging path used elsewhere, including per-host deploy log
  files.
- Simplified the remote dispatcher report to stream the dispatcher invocation
  journal directly and filter only known systemd noise, preserving
  dispatcher-side diagnostics while still avoiding boilerplate.
- Wrapped deploy-context setup and remote report collection in a single helper
  executed under the combined host logging path, so both stages are prefixed
  consistently and written into the per-host deploy log.
- Changed the report helper to emit explicit "report unavailable" diagnostics
  and return the underlying failure status when context setup or remote report
  collection fails.

## Validation

- `bash -n lib/systemd-user-manager/helper.sh pkgs/nixbot/nixbot.sh`
- `shellcheck lib/systemd-user-manager/helper.sh pkgs/nixbot/nixbot.sh`
  - only pre-existing informational `SC2016` notes remain in
    `pkgs/nixbot/nixbot.sh`
