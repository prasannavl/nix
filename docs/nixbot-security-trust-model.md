# Nixbot Security Trust Model

This document defines the trust boundary for `nixbot` deploy access, especially
for bastion-triggered runs and arbitrary `--sha` execution.

## Core Assumption

Possession of a bastion `nixbot` ingress key means the holder is a trusted
deploy operator.

That trust includes the ability to:

- trigger deploy flows on bastion
- select arbitrary reachable Git SHAs for execution
- cause bastion to evaluate/build repo content at those SHAs
- use deploy paths that rely on bastion-resident secrets and keys

This is an administrative trust boundary, not a review boundary.

## What Bastion-Trigger Access Means

`--bastion-trigger` access is intentionally high privilege.

A trusted operator with bastion-trigger access may:

- run reviewed `master`
- run an unreviewed branch commit by SHA
- run dry-runs or real deploy flows, subject to workflow policy

The current model does not treat Git review alone as a hard security barrier for
holders of bastion-trigger credentials.

## What The Installed Wrapper Protects

The installed bastion wrapper still provides meaningful protection:

- CI/operators cannot SCP an arbitrary shell script to bastion and execute it
- normal runs stay pinned to the installed packaged `nixbot` entrypoint
- per-run repo worktrees isolate execution state from the persistent repo root
- `--use-repo-script` remains opt-in for intentionally executing fetched script
  code

These protections reduce accidental and opportunistic abuse, but they do not
turn bastion-trigger operators into low-trust users.

## Arbitrary SHA Policy

Arbitrary SHA execution is allowed because bastion-trigger key holders are
already trusted as deploy admins.

That implies:

- a private branch pushed to origin may be run by SHA on bastion
- review requirements are workflow/process controls for trusted operators
- review is not the final cryptographic or runtime enforcement point for this
  operator class

If that assumption changes in the future, `nixbot` should restrict `--sha` to
commits reachable from `origin/master` or another explicitly trusted ref set.

## Secrets And Key Exposure

Bastion-trigger operators must be treated as capable of causing privileged repo
evaluation in a context where deploy secrets and keys exist.

Therefore:

- bastion ingress keys are highly sensitive credentials
- anyone holding them must be trusted not to intentionally exfiltrate secrets
- branch isolation or PR review alone is not sufficient mitigation against a
  malicious bastion-trigger operator

## Practical Consequences

- Do not distribute bastion `nixbot` ingress keys broadly.
- Treat bastion-trigger access like privileged production deploy access.
- Use workflow policy to limit who may run non-dry deploys on `master`.
- Use worktrees for concurrency/isolation, not as a substitute for operator
  trust reduction.

## Related Docs

- `docs/deployment.md`
- `pkgs/nixbot/nixbot.sh`
