# Flake Collections Lib Location

- Move the shared `duplicateValues` helper from `lib/collections/default.nix` to
  `lib/flake/collections/default.nix`.
- Update in-repo imports to reference `../flake/collections` so the helper lives
  with the rest of the flake-oriented library helpers.
