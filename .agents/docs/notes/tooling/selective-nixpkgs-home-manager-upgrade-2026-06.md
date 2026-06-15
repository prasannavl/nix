# Selective Nixpkgs and Home Manager Upgrades

## Context

Selective host upgrades must happen at host construction time, before NixOS
module evaluation chooses `pkgs`, overlays, Home Manager, agenix, and disko. Do
not implement this as a late host module override of `nixpkgs.pkgs` or Home
Manager options after the system is already constructed.

## Shape

The root flake delegates final output assembly to `lib/flake/root.nix`:

```nix
outputs = inputs:
  (import ./lib/flake/root.nix {inputs = inputs;}).outputs;
```

`lib/flake/root.nix` intentionally exposes only final flake outputs:

```nix
{
  outputs = ...;
}
```

Profile maps, `mkNixosSystem`, stacks, overlays, package outputs, and dev-shell
assembly are local implementation details inside `root.nix`. The root flake
should not grow a second public helper API beside normal flake outputs.

Profiles are coherent input sets. `stable` uses the existing 25.11 inputs.
`next` uses `nixpkgs-next` on `nixos-26.05` plus matching `*-next` inputs for
host evaluation. The raw `unstable` input remains `nixos-unstable` and is not a
host profile.

The PVL repo has additional host-consumed inputs beyond the Abird server repo:
`antigravity`, `p7-borders`, `p7-cmds`, and `noctalia` are consumed by host
packages, overlays, or Home Manager modules. `llm-agents` is currently root
tooling, but it also follows `nixpkgs` and `treefmt-nix`, so it has a
`llm-agents-next` twin to keep profile input sets mechanically complete. These
inputs have `*-next` twins in the `next` profile so a next host does not
accidentally evaluate package or module inputs against stable-follow inputs.

`mkNixosSystem` defaults to:

- `inputProfile = inputProfiles.stable`
- `system = "x86_64-linux"`

Hosts normally omit both. Add `inputProfile = inputProfiles.next;` for canaries
and `system = "aarch64-linux";` only for non-x86 hosts. `pvl-vlab` is the
current PVL next-profile canary.

## Host Manager

`host-manager generate` stays repo-agnostic and emits direct `mkNixosSystem`
entries with an optional explicit `stack = stacks.<name>;`. It does not use
local convenience wrappers and does not emit the default `system`.

## Compatibility Findings

Nixpkgs 26.05 exposed two shared compatibility seams:

- `pkgs.nixVersions.nix_2_33` is not available on newer nixpkgs, so
  `lib/nix.nix` selects `nix_2_34` when present and falls back to `nix_2_33`.
- `services.resolved.extraConfig` is removed on newer nixpkgs, so `lib/mdns.nix`
  uses `services.resolved.settings.Resolve` when that option exists and keeps
  `extraConfig` for stable 25.11.
- GDM 50 renamed the register-timeout constant in `common/gdm-common.h` from
  `REGISTER_SESSION_TIMEOUT` to `REGISTER_DISPLAY_TIMEOUT`. Keep the local GDM
  timeout patch as a guarded `postPatch` substitution in `overlays/gdm.nix`
  instead of a brittle single-context patch file, so stable GDM 49 and next GDM
  50 both build. Keep package-specific overlay tweaks in package-named files
  such as `overlays/gdm.nix` and `overlays/supergfxctl.nix`; reserve
  `overlays/pvl.nix` for the `pvl.*` namespace and its derived package-set
  exports. Validate the GDM-specific failure with
  `nix build --no-link .#nixosConfigurations.pvl-a1.pkgs.gdm`; this caught the
  former failed `gdm-register-session-delay-3s.patch` application and passes
  once the guarded substitution is used.
- Mutter 50 removed `variable-refresh-rate` from the accepted
  `org.gnome.mutter experimental-features` flag set. Keep shared GNOME and GDM
  settings derived from `pkgs.mutter.version`: enable
  `scale-monitor-framebuffer` and `xwayland-native-scaling` for all current
  profiles, and add `variable-refresh-rate` only before Mutter 50.
