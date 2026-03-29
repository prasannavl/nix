# Podman Lifecycle Tag Semantic Stamps

## Context

`lib/systemd-user-manager.nix` persisted action and managed-unit stamps by
hashing the full generated definition payload. For Podman lifecycle tags, that
meant generated helper script paths inside `argv` or other incidental unit
changes could alter the stamp even when the declarative tag value itself had not
changed.

That behavior was wrong for `imageTag`, `bootTag`, and `recreateTag`. These are
meant to be explicit operator knobs, not side effects of unrelated refactors or
helper regeneration.

## Decision

Add optional `stampPayload` overrides to systemd-user-manager actions and
managed units.

Use those overrides in `lib/podman.nix` so:

- the `image-tag` transient pre-action stamp is keyed only to the action name
  and declared `imageTag` value
- the main Podman managed-unit stamp still reflects normal stack-change restart
  semantics through `restartStamp`
- the tag-specific portion of the main managed-unit stamp depends only on the
  declared `bootTag` and `recreateTag` values

## Outcome

- `imageTag` now runs only when the declared `imageTag` value changes
- `bootTag` and `recreateTag` now affect reconciliation only when their declared
  values change
- unrelated helper script churn or generated store-path changes no longer fire
  Podman lifecycle tags
