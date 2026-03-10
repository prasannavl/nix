# Nixbot Snapshot Fallback During Dependency-Ordered Deploys (2026-03)

## Problem

`scripts/nixbot-deploy.sh` tried to snapshot `/run/current-system` for every
selected host before any deployment started. If a host was intentionally down or
not yet resolvable until a dependency host came up, the whole run aborted before
the dependency-ordered deploy could start that host.

## Decision

- Keep the initial snapshot sweep across all selected hosts so reachable nodes
  still capture pre-deploy rollback state as early as possible.
- Treat initial snapshot failures as deferred, not fatal.
- Before each deploy step, retry snapshots for the host or current dependency
  wave.
- Refuse to deploy a host if its rollback snapshot is still unavailable when its
  wave is reached.

## Effect

- New nodes that become reachable only after dependency hosts are deployed can
  now proceed in the same run.
- Rollback guarantees stay intact because a host still needs a recorded
  pre-deploy generation before its deployment actually starts.
