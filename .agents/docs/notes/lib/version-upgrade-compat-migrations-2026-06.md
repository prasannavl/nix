# Version Upgrade Compatibility Migrations

Use migration-shaped compatibility code when a version upgrade needs to bridge
old and new runtime state. Keep the long-term config on the target version's
native shape.

## Pattern

- Put compatibility in the owning module, close to the runtime boundary it
  affects.
- Gate temporary behavior with evaluated package or option shape only while the
  repo still supports both sides of the transition.
- Keep version gates highly contained: prefer the smallest local `let`, attr
  value, or helper expression that owns the incompatible shape. Do not let
  `versionOlder`/`versionAtLeast` branches sprawl across a module or force broad
  rewrites of otherwise stable declarations.
- Make the target-version declaration easy to read without mentally executing
  the compatibility branch. If the compat case needs more than a few lines,
  isolate it in a named local helper and keep the normal path plain.
- Prefer a one-time activation or service migration when the problem is mutable
  host state, such as existing accounts, profiles, caches, unit state, or
  generated files.
- Make one-time migrations idempotent: no-op after convergence, fail loudly on
  partial cleanup, and leave a marker only after the target state is actually
  restored.
- Remove compatibility branches after the fleet has crossed the boundary. Keep a
  note with the removed branch and the migration reasoning so the pattern can be
  recreated for the next upgrade.

## Examples

- Mutter/GNOME feature flags: remove old-version branches such as
  `mutterLessThan50` after the fleet is on GNOME 50, but keep the current
  target-version feature list if it is still valid.
- systemd-resolved options: remove pre-260 `extraConfig` fallbacks after the
  fleet is on systemd 260, and keep the native `settings.Resolve` declaration.
- GDM greeter accounts: the NixOS 26.05 UID/suffix shift showed why mutable host
  state may need a one-time migration. The migration experiment also showed that
  active display-manager greeter sessions can interact with
  `switch-to-configuration-ng` user-manager reloads, so future account
  migrations should account for active logind users before activation reaches
  the generic user reload phase.
