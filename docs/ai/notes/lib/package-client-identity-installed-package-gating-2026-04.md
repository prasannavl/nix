# package client-identity installed-package gating

- Date: 2026-04-13
- Scope: `lib/flake/service-module.nix`

## Decision

Gate package-owned `clientIdentity` module fragments on whether the owning
package is actually installed in `config.environment.systemPackages`.

## Why

- The root flake imports package-owned NixOS modules globally for every host.
- `srv.mkClientIdentity build` exported a module that always added its
  `age.secrets` when the encrypted files existed in the repo.
- That caused hosts to try decrypting secrets for packages they did not install.
- The failure surfaced on `gap3-gondor` during deploy because the global
  `nats-wrecking-ball` client-identity module made the parent host materialize
  `gap3-rivendell`'s client cert and key, but those secrets were encrypted only
  to the guest recipient.

## Applied shape

- When `srv.mkClientIdentity` is created from a derivation, its exported
  `nixosModule` now uses
  `lib.mkIf (builtins.elem drv
  config.environment.systemPackages)` before
  adding `age.secrets`.
- Direct non-derivation identities still export unconditional `age.secrets`
  fragments, which keeps explicit host-owned identity use sites working.

## Result

- Package-owned client cert/key secrets only materialize on hosts that install
  the package.
- Cross-host secret recipient scopes stay aligned with the actual runtime
  consumer set instead of the global package/module export set.
