# Abird Latest Incus Port 2026-07

Reviewed the newest Abird commit after `07375d74`, ending at `19c57198`, from
local base `32a13cb1`.

## Logical Units

- Incus preseed reactivation: `19c57198` is the same shared Incus fix already
  landed locally as `32a13cb1`.
- Local docs adaptation: this repo records the incident in
  `.agents/docs/notes/hosts/pvl-x2-incus-preseed-reactivation-2026-07.md`
  instead of copying Abird's consolidated Incus platform note.

## Commit Ledger

| Commit     | Subject                                     | Disposition                                                                                                                           |
| ---------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `19c57198` | `fix(incus): rerun preseed on reactivation` | Already adopted locally as `32a13cb1`; `lib/incus/default.nix` and `lib/incus/tests/module.nix` are byte-identical to `abird/master`. |

## Byte-Parity Targets

The shared code parity set for this audit is:

- `lib/incus/default.nix`
- `lib/incus/tests/module.nix`

## Intentional Divergences

- `.agents/docs/**` remains adapted to this repo's docs structure. The Abird
  consolidated note
  `.agents/docs/notes/hosts/incus-platform-consolidated-2026-04.md` was not
  ported because the local equivalent is the `pvl-x2` incident note.
