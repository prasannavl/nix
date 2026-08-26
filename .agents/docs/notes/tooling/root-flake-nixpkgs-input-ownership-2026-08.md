# Root Flake Nixpkgs Input Ownership

## Context

The root flake intentionally owns two Nixpkgs channels:

- `nixpkgs` is the coherent `nixos-26.05` package set used by hosts and root
  tooling.
- `unstable` is the separately consumed `nixos-unstable` package set.

`nixos-hardware` previously kept its upstream `nixpkgs` input instead of
following the root input. That upstream input resolved through the mutable NixOS
unstable channel tarball, so `flake.lock` contained three Nixpkgs source nodes:
the transitive tarball as `nixpkgs`, the root stable channel as `nixpkgs_2`, and
the intentional root `unstable` channel.

## Ownership Rule

Root dependencies that expose a `nixpkgs` input must follow the root `nixpkgs`
input unless the repository has a documented compatibility reason to own a
separate package set. Declare that contract in `flake.nix`; do not normalize
generated node names by editing `flake.lock` directly.

`nixos-hardware` therefore uses:

```nix
nixos-hardware = {
  url = "github:nixos/nixos-hardware";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Do not make `unstable` follow `nixpkgs`: it is a first-class root input with a
different channel and consumer contract.

## Validation

After changing root inputs, regenerate the lock with `nix flake lock`. The lock
graph should contain exactly one node for `nixos-26.05` and one node for
`nixos-unstable`, with no transitive Nixpkgs tarball. Validate the evaluated
graph and root outputs with:

```bash
nix flake metadata --json .
nix --option allow-import-from-derivation false flake check --no-build .
```
