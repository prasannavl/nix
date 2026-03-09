# Podman Compose `envSecrets` schema simplification (2026-03-09)

## Summary

- Removed the redundant `files` nesting from `services.podmanCompose.*.instances.*.envSecrets`.
- The schema is now `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret`.

## Reasoning

- The outer `envSecrets` attrset already scopes entries by compose service.
- The inner `files` wrapper did not carry additional semantics; it only added an
  extra layer the module immediately unwrapped again.
- Keeping the compose-service layer preserves the ability to inject different
  generated `env_file` outputs into different services within the same compose
  stack.

## Module changes

- Updated `lib/podman.nix` so `envSecrets` is typed as an attrset of attrsets of
  string paths.
- Adjusted secret env-file generation and assertions to iterate directly over
  `envSecrets.<composeService>`.

## Host changes

- Updated `hosts/pvl-x2/services.nix` to use the simplified shape for `beszel`,
  `shadowsocks`, `immich`, and `docmost`.
