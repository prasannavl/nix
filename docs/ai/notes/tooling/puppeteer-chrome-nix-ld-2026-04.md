# Puppeteer Chrome On NixOS

## Context

- Local Puppeteer installs can download upstream Chrome/Chromium binaries into
  tool-managed cache directories. Those binaries are not Nix-patched and expect
  distro-style shared libraries.
- `lib/nix-ld.nix` is imported by the core profile and should stay limited to
  shared `nix-ld` enablement.

## Decision

- Keep `programs.nix-ld.enable = true`.
- On `pvl-a1`, populate `programs.nix-ld.libraries` from
  `hosts/pvl-a1/nix-ld.nix` with the Chrome runtime library set mirrored from
  the Nixpkgs `google-chrome` package.
- Prefer this for downloaded Puppeteer browsers. For repo-owned Node packages
  that can be controlled directly, using Nixpkgs `chromium` plus
  `PUPPETEER_EXECUTABLE_PATH` remains a narrower alternative.
