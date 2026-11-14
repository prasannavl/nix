# Managed provider contract

`default.nix` exports `managed-byok-provider`, a generic package check with a
synthetic non-null provider. Import it with `{ pkgs; }` from the root check
aggregator. It uses the canonical constructor and unchanged source/runtime pins;
no host declaration, proxy policy, credentials or live inference service is
needed.

The package build applies `../managed-byok-provider.patch` and runs its Vitest
suite before building the web application. A null `managedByokProvider` skips
that suite, so checking only the unconfigured image is insufficient. This
registration intentionally exercises the non-null path without depending on a
host override.

Coverage: seed and persist only absent config; retain personal selections and
keys; ignore stale managed markers as ownership evidence; preserve invalid or
unreadable storage; tolerate failed persistence for a fresh session.

This check builds the complete image, including native dependencies. Schedule it
outside resource-constrained test lanes. A patch-application check or a focused
Vitest run does not replace full package qualification.
