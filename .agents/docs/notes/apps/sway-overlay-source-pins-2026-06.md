# Sway Overlay Source Pins

The Sway git overlay owns its upstream source pins locally in
`overlays/sway.nix`, not as root `flake.nix` inputs. Keep the root flake clean
unless the source is shared outside this overlay.

`overlays/default.nix` keeps the Sway overlay import commented out by default.
Uncomment that import to opt back into the git compositor stack.

The local pins use `builtins.fetchTree` with explicit `rev` and `narHash` values
copied from the former flake lock entries. The old `src = inputs.<name>;` lines
are intentionally kept as comments next to each replacement source assignment so
switching back to root inputs is straightforward if that ownership boundary
changes later.

The Sway overlay also carries the xdg-desktop-portal git pins because those
overrides are part of the same compositor experiment. If the overlay is removed
from `overlays/default.nix`, these source fetches stop being part of the default
package overlay surface.

When forcing `xdg-desktop-portal-git`, import the package from unstable's
by-name path:

```nix
${inputs.unstable}/pkgs/by-name/xd/xdg-desktop-portal/package.nix
```

The older `pkgs/development/libraries/xdg-desktop-portal/default.nix` path is no
longer present in current unstable nixpkgs.
