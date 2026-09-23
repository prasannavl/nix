# AI consumer endpoint host regression, 2026-09

## Context

`worktrees/ai-consumer-endpoint-regression-20260923` on branch
`codex/ai-consumer-endpoint-regression-20260923` carried the Pvl-side mirror of
Abird's AI consumer endpoint series. Its commits (`2439daec`, `074f51c8`,
`ff7c9b05`, `c0c3ba3c`) were already merged to `master`; only an uncommitted
follow-up fix remained in the worktree.

## Root cause

`lib/services/ai/projection.nix::mkConsumers` built the consumer-facing
`endpoints` output as `endpoint // {url = resolveUrl endpoint;}`. An endpoint
declared as `{port;}` therefore produced `{port; url;}`, even though the shared
test `lib/services/ai/tests/projection.nix` and the documented consumer view
expect the descriptor to normalize an omitted host to `defaultHost` as
`{host = "default"; port; url;}`. The `url` value was already correct, so only
the descriptor shape diverged and `lib-ai-projection` failed on `master`:

```
error: attribute names of attribute set '{ port = 3; url = "http://default:3"; }'
       differs from attribute set '{ host = "default"; port = 3; url = "http://default:3"; }'
```

## Fix

`resolved` now fills `host = endpoint.host or defaultHost` for descriptors that
do not carry a fully resolved `url`; URL-owned descriptors are left untouched.
`lib/services/ai/tests/projection.nix` needed no change.

## Evidence

- `nix-build lib/tests/default.nix -A lib-ai-projection` failed on the pre-fix
  `master` and passes with the fix.
- Commit `fix(ai): normalize consumer endpoint hosts` on the worktree branch
  (`581698de`), cherry-picked to `master` (`0d8b031a`) and pushed to
  `origin/master`. The pre-push diff lint passed.

## Abird parity

`git fetch abird` advanced `abird/master` to `6fa0b6fb`, 24 linear commits past
the last recorded shared boundary `857ac6eb` (the AI endpoint-projection
series). Byte comparison of shared paths shows every `lib/services/ai`,
`lib/services/llama-router`, `lib/ext/prism-llama-cpp`,
`pkgs/support/nats-streams`, and shared test-registration file identical except
`lib/services/ai/projection.nix`:

- Pvl `master` carries the host-normalization fix (`c89ca636`).
- Abird `6fa0b6fb` still carries the pre-fix blob (`a79ee8f6`), while its copy
  of `lib/services/ai/tests/projection.nix` is byte-identical to Pvl's and
  expects the normalized host. Abird's equivalent projection check is therefore
  expected to fail until this fix is reverse-ported.

Abird-only identity paths (`pkgs/support/nats-streams/*chat-intelligence*`,
`hosts/abird-corp/**`, `hosts/abird-srv/**`, plans, and Abird reverse-port
ledgers) remain intentionally excluded.

## Worktree disposition

The branch and worktree are clean and can be removed once the cherry-picked
`master` commit is accepted; the sibling `ai-artifact-serving-profiles` worktree
carries a superset `resolveEndpoint` variant and is unrelated to this fix.
