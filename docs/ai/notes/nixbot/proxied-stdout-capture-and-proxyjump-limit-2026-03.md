# Proxied Stdout Capture And ProxyJump Limit

## Context

Parented child deploys still failed after the broader parented preflight retry
loop was added.

More verbose logs showed a different failure mode during remote temp-file
allocation and copy:

- child-hop SSH sometimes emitted the normal first-contact message
  `Warning: Permanently added ...`
- nixbot captured `ssh` stdout and stderr together while expecting a clean temp
  path on stdout
- the warning text was concatenated with `/tmp/nixbot-age-identity.*`, so `scp`
  treated the whole blob as the destination path and failed

This was distinct from the earlier transport-reset failures.

## Decision

For machine-readable remote captures, keep stdout and stderr separate.

`nixbot` now uses a stdout-only transport capture helper for remote temp-file
allocation and lets stderr stream normally to the operator.

It also sets `LogLevel=ERROR` on generated SSH contexts and proxy scripts so
first-contact `accept-new` chatter does not leak into structured output paths.

## ProxyJump Follow-Up

Raw `ProxyJump` is not a drop-in replacement for the current proxy wrapper in
this topology.

A direct test with:

- the same deploy key
- a per-run `UserKnownHostsFile`
- `ssh -J nixbot@pvl-x2 nixbot@10.10.20.11`

failed on the jump host with `Permission denied (publickey)`, which indicates
the top-level identity/options were not sufficient for the jump leg itself.

That means a future ProxyJump migration should use a generated SSH config with
per-hop aliases and hop-specific identity/known-hosts settings, not a simple
`ProxyCommand` -> `ProxyJump` text substitution.
