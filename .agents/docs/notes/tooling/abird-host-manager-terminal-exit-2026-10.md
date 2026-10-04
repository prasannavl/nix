# Abird Host Manager Terminal Exit Teardown

## Symptom

An interactive `abird-host-manager` run sometimes exited with the shell prompt
glued to the last live-region row (the `keys: ...` footer) and no line break:

```text
keys: v: verbose · ... · ctrl-c: cancel[18:28:47|pvl@pvl-l5:~/src/nix] (master[>>])
```

Other runs showed the same footer correctly terminated. The difference tracked
the terminal height and the amount of streamed content, not the host.

## Root cause

The live region has two paint paths in `src/progress.rs`:

- `Painted::InPlace` writes `lines.join("\n")` with no trailing newline, so the
  cursor stays at the end of the last painted row;
- `Painted::Snapshot` (a frame as tall as the viewport) writes
  `format!("{}\n", lines.join("\n"))`, already ending on a fresh line.

Nothing tore the region down when the process exited. The last durable write is
usually a permanent line, but an active verbose section keeps re-rendering the
`Logs` region after the span stack empties, so the final frame is often an
in-place region whose footer never gets a newline. A run whose final frame was a
snapshot looked correct. `main` returned an `ExitCode` without any explicit
terminal teardown, so the mode was only restored by the `InteractiveVerbose`
guard's `Drop`; a panic or early return could still strand the region.

## Contract

`progress::finish_terminal()` is the single exit teardown: it releases the live
region and restores the terminal mode captured by `terminal_mode`. It is
idempotent and a no-op when nothing entered raw mode or painted a region.

- `release_live_region`: an in-place frame gets `\r\n`; a snapshot frame is
  already terminated; the painted state is cleared either way so a second call
  writes nothing.
- `terminal_mode::restore_published()` restores the published snapshot and is a
  no-op when raw mode was never entered. `restore_for_forced_exit` now delegates
  to it and keeps the async-signal-safe property.
- `progress::guard_terminal_exit()` installs a panic hook (best-effort,
  non-blocking so a lock the panicking thread holds cannot deadlock) and returns
  a `TerminalExitGuard` whose `Drop` runs the blocking teardown. Both `main` and
  the `nixbot` bin call it first, so success, error, and panic exits all hand
  the terminal back on a fresh line.

The signal forced-exit path already restored the mode and printed a leading
newline, so it needed no change.

## Validation

`cargo test -p abird-host-manager` (lib + integration) passes. New lib tests:

- `releasing_an_in_place_live_region_ends_the_line_once`
- `releasing_a_snapshot_live_region_adds_no_extra_newline`
- `releasing_a_non_interactive_region_is_a_no_op`
