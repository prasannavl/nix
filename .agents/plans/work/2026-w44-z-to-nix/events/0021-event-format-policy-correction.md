# Event-format policy correction

- Canonical batch-08 lint exposed a source-policy gap in pinned Deno 2.8.3. With
  ordinary documentation before event arguments, the repository invocation
  ignored the exclusion glob and reported raw event formatting drift. Reversing
  those arguments passed. Event bytes remained unchanged throughout.
- Minimal isolated fixtures did not reproduce that dependency behavior. The
  initial six-case fixture was therefore insufficient for the real invocation.
- Filter NUL-framed plan-event paths before invoking Deno. Retain source
  treefmt/Markdownlint auto-fix exclusions and read-only Markdown lint.
- Nine registered cases pass. Enforce no event argument reaching Deno; a logging
  shim delegates to the pinned binary. Source glob-only policy violates this
  invariant even where its glob happens to work. Also cover old-policy mutation,
  ordinary files, non-plan events, spaces/newlines and root-level events.
- Preserve event 0020 and all earlier records. This correction adds no source
  queue rows, formatter version change or general lint exemption. Carry the
  filter and generic regression back during later convergence.
