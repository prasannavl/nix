# Nixbot Security Trust Model

`nixbot` bastion-trigger access is a trusted deploy-operator boundary.

## Core Rule

Anyone holding a bastion `nixbot` ingress key must be treated as a trusted
deploy operator.

That trust includes the ability to:

- trigger deploys on bastion
- select arbitrary reachable Git SHAs
- cause bastion to evaluate and build repo content at those SHAs
- use deploy paths that rely on bastion-resident secrets and keys

This is an administrative trust boundary, not a code-review boundary.

## What The Wrapper Protects

The installed wrapper still provides useful guardrails:

- CI and operators do not upload arbitrary shell scripts to bastion
- normal runs stay pinned to the packaged `nixbot` entrypoint
- detached worktrees isolate run state from the persistent mirror
- `--use-repo-script` remains opt-in

These are containment and hygiene controls. They do not make bastion-trigger
users low-trust.

## Arbitrary SHA Policy

Arbitrary SHA execution is allowed because bastion-trigger users are already in
the trusted deploy-operator class.

If that assumption changes, `nixbot` should restrict `--sha` to commits
reachable from explicitly trusted refs.

## Secret Exposure

Bastion-trigger operators must be treated as capable of causing privileged repo
evaluation in a context where deploy secrets and keys exist.

Operational consequences:

- keep bastion ingress keys tightly scoped
- treat bastion-trigger access like privileged production deploy access
- do not rely on branch isolation or PR review as protection against a malicious
  bastion-trigger operator

## Related Docs

- [`docs/deployment.md`](./deployment.md)
- `pkgs/tools/nixbot/`
