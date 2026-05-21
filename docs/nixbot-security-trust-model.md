# Nixbot Security Trust Model

`nixbot` CI host-trigger access is a trusted deploy-operator boundary.

## Core Rule

Anyone holding a CI host `nixbot` ingress key must be treated as a trusted
deploy operator.

That trust includes the ability to:

- trigger deploys on CI host
- select arbitrary reachable Git SHAs
- cause CI host to evaluate and build repo content at those SHAs
- use deploy paths that rely on CI host-resident secrets and keys

This is an administrative trust boundary, not a code-review boundary.

## What The Wrapper Protects

The installed wrapper still provides useful guardrails:

- CI and operators do not upload arbitrary shell scripts to CI host
- normal runs stay pinned to the packaged `nixbot` entrypoint
- detached worktrees isolate run state from the persistent mirror
- `--use-repo-script` remains opt-in

These are containment and hygiene controls. They do not make CI host-trigger
users low-trust.

## Arbitrary SHA Policy

Arbitrary SHA execution is allowed because CI host-trigger users are already in
the trusted deploy-operator class.

If that assumption changes, `nixbot` should restrict `--sha` to commits
reachable from explicitly trusted refs.

## Secret Exposure

CI host-trigger operators must be treated as capable of causing privileged repo
evaluation in a context where deploy secrets and keys exist.

Operational consequences:

- keep CI host ingress keys tightly scoped
- treat CI host-trigger access like privileged production deploy access
- do not rely on branch isolation or PR review as protection against a malicious
  CI host-trigger operator

## Related Docs

- [`docs/deployment.md`](./deployment.md)
- `pkgs/tools/nixbot/`
