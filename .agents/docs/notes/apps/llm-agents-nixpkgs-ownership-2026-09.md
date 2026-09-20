# llm-agents Nixpkgs ownership

On 2026-09-21, the root flake stopped forcing the `llm-agents` input to follow
the repository's stable Nixpkgs input. The `systems` and `treefmt-nix` follows
remain shared.

## Decision

`llm-agents` owns the Nixpkgs revision used to construct its package outputs.
The repository consumes those outputs directly for `chatgpt` and
`claude-desktop`; it does not use the shared-Nixpkgs overlay or a NixOS module
that must share the host package set.

This adds a separate Nixpkgs lock node for `llm-agents` while the repository's
root Nixpkgs remains on the selected stable release.

## Reason

The `llm-agents` package set tracks `nixpkgs-unstable` package APIs. Revision
`eacea85aeddb2b401e907b562c0b2f3640da615f` requires `electron_44` for its
`t3code` package. Root Nixpkgs revision
`6d663c0533ff269008fb84e45930151e37c99db9` provides Electron 43 but not Electron
44, so forcing the input to follow root Nixpkgs made the complete package set
fail during `pvl-a1` evaluation even though that host selects only `chatgpt` and
`claude-desktop`.

Upstream's own Nixpkgs revision `0a3468a402c449992505b6a9fc5b06580141b750`
provides Electron 44 and evaluates the package set coherently. Do not alias
Electron 44 to an older major or hide the failing package through lazy
selection; either approach would mask the dependency contract instead of
satisfying it.

## Validation

With import-from-derivation disabled:

- `pvl-a1` resolved `chatgpt-26.915.31945` and `claude-desktop-2.2553.1` from
  `llm-agents`.
- All seven declared NixOS configurations evaluated their system toplevel
  derivation paths successfully.

Re-run the full host evaluation whenever either the root or `llm-agents` Nixpkgs
revision changes. Direct application derivations from the separate package set
may coexist in `environment.systemPackages`; this decision does not authorize
importing `llm-agents` modules or overlays across the package-set boundary
without a separate compatibility review.

## Source of truth files

- `flake.nix`
- `flake.lock`
- `hosts/pvl-a1/packages.nix`
