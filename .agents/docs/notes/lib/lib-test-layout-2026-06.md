# Lib Test Layout 2026-06

Use `lib/tests` for cross-cutting tests of `lib/**` code that does not have a
more specific owner directory. Keep module-local tests next to modules that
already own their own helper/module surface, such as `lib/incus/tests`,
`lib/podman-compose/tests`, and `lib/systemd-user-manager/tests`.

Use `lib/flake/tests` for the isolated `lib/flake` helper surface. These tests
should avoid depending on repo host modules or real stack profiles unless that
is the behavior being tested.

Root flake `checks` should expose these lib tests directly so `nix flake check`
and targeted `nix build .#checks.<system>.<name>` runs exercise them. The broad
profile test that used to live under `lib/profiles/tests` now belongs to
`lib/tests/profiles-incus-lxc.nix` as `lib-profiles-incus-lxc`.
