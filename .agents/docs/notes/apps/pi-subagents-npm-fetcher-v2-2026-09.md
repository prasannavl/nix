# pi-subagents npm dependency fetch (fetcher v2)

On 2026-09-23, `./scripts/update.sh` failed while updating `pi-subagents` 0.70.0
-> 0.71.0.

## Root cause

`pi-subagents` used the default `buildNpmPackage` npm dependency fetcher
(`npmDepsFetcherVersion` unset, i.e. v1). For the 0.71.0 lockfile, the fetcher's
`_cacache` did not satisfy `npm install` for the newly pulled transitive
`@earendil-works/pi-tui@0.87.0`. The package build failed with
`npm error code
ENOTCACHED` ("cache mode is 'only-if-cached' but no cached
response is available") even though the fixed-output derivation's hash matched.

Because the suite updater replaces `sources.nix` only after every requested
package validates, the failure discarded the whole pi staging run, including the
already successful `pi-models-discovery` 1.4.0 build.

## Fix

Set `npmDepsFetcherVersion = 2;` in `lib/ext/pi/pi-subagents/default.nix`,
matching the existing `lib/ext/pi/pi-web/default.nix`. The `sources.nix` schema
is unchanged; the updater's fake-hash rebuild flow recomputes the new
`npmDepsHash`.

## Validation

- `lib/ext/pi/update.sh --package pi-subagents` built and installed 0.71.0.
- `lib/ext/pi/update.sh` then rebuilt all five packages and installed
  `pi-models-discovery` 1.4.0, `pi-subagents` 0.71.0, and `pi-web` 0.9.3.

## Related

The outer `scripts/update.sh` still stops earlier in
`lib/ext/neovim-plugins/update.sh` because the unauthenticated GitHub API
returned HTTP 403 (rate limit). That updater honours `GITHUB_TOKEN`, so rerun
with a token or after the limit resets; it is unrelated to this fix.
