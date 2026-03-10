# Nixbot Deploy Log Formatting (2026-03)

## Scope

Improved `scripts/nixbot-deploy.sh` log readability for GitHub Actions and
manual runs without changing deploy behavior.

## Changes

- Added simple section headers for major phases: run start, remote trigger,
  repo re-exec, build, snapshot, deploy, rollback, and run complete.
- Added lightweight per-host stage headers for build, deploy, snapshot, and
  rollback operations.
- Added deploy-wave and snapshot-wave headers so dependency-group execution is
  easier to scan in parallel runs.
- Shortened per-host lines so they favor host/stage markers and key values over
  sentence-style prose.
- Strengthened host separation with explicit host banners and a more visible
  per-line host prefix for interleaved parallel output.
- Renamed the top-level start banner to `nixbot` and normalized phase headers
  to `Phase: <name>`, including per-host phase labels.
- Tightened host-local labels by removing `Phase:` from per-host lines while
  keeping phase names in the host banners.
- Reformatted startup and summary host lists into newline-separated blocks for
  easier scanning of selected, successful, and failed hosts.
- Changed the final summary to a per-host status list (`ok` / `FAIL (...)`)
  instead of phase-grouped buckets, with an explicit failure banner when any
  host ends in a failed state.
- Adjusted summary semantics so a host that deployed successfully and was later
  reverted due to another host's failure is labeled `rolled back` rather than a
  host-local `FAIL`.
- Assigned distinct banner surrounds to major phases so build, snapshot,
  deploy, rollback, summary, and startup are visually differentiated.
- Reused the same phase-specific surrounds for host banners, while keeping the
  generic `=` style for the top-level phase banners and summary.
- Kept the per-phase distinct surround characters only on host-specific
  banners, so section headers stay uniform while host blocks remain visually
  differentiated.
- Made host line-prefixing consistent for both sequential and parallel
  execution paths, so streamed logs always retain `| host | ...` attribution.
- Added `--prefix-host-logs` / `DEPLOY_PREFIX_HOST_LOGS` so single-job phases
  can opt into host prefixes; otherwise prefixes are now automatic only when
  the relevant phase is actually parallel.
- Simplified prefix control so resolved host-prefix behavior is driven by a
  single boolean. If not explicitly set, parallel build/deploy job counts now
  flip that boolean on as a default.
- Refactored the build-path selection into a shared helper and dropped the
  unused phase argument from the host log filter to trim duplicated branching.
- Moved the log-formatting helper functions to the end of
  `scripts/nixbot-deploy.sh` so the deploy flow stays grouped ahead of the
  presentation helpers.
- Replaced the generic completion banner with a final summary that lists
  success/failure by build, deploy, and rollback phase.
- Kept the output intentionally plain text and stderr-oriented so existing
  piping and host-prefixed log capture still work.

## Intent

- Make CI logs easier to scan by stage and host.
- Preserve current control flow, command behavior, and failure semantics.
