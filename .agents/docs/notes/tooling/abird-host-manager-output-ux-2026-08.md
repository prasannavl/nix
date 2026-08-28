# Abird Host Manager Output UX

## Contract

`abird-host-manager` has one presentation protocol across commands, without
forcing every operation into the move transaction state machine. Every public
command leaf declares one output contract:

- `Structured`: one typed result with a semantic human view or one unchanged
  JSON document;
- `Stream`: an undecorated bounded or followed stream, including journal text
  and JSONL; or
- `Passthrough`: a byte-transparent interactive SSH or remote-command stream.

Global `--json` applies only to structured commands. Logs use their own
`--output json` JSONL contract. SSH and exec do not buffer or envelope the
remote byte stream.

## Human views

Structured commands select an explicit inspection, collection, action, fleet,
workflow, backup, or job view. Internal JSON serialization fields do not select
the view. In particular, backup records cannot be mistaken for transactions
merely because both contain `spec` and `phase` fields.

The visual vocabulary is semantic:

- read-only inspection reports facts without a success glyph;
- `✓` means terminal success or an already-satisfied postcondition;
- `●` means accepted, running, or otherwise nonterminal work;
- `◇` means work deliberately deferred to deployment or a dry-run check that was
  not executed;
- `✗` means failure; and
- dry runs say that no changes will be made and never claim success.

Durable agent submission is not completion. Job views derive their state from
the retained job record. Fleet output retains one row per host and one overall
failure result, including partial success. Reboot reports submission rather than
claiming that a host completed its reboot.

Inspection and dry-run paths open both workflow and backup state read-only. A
missing state root remains missing; `list` reports an empty collection instead
of creating manager state.

## Interactive color

Color reinforces the existing glyph and prose vocabulary; it never replaces it.
Interactive terminals use one restrained semantic palette: success is bold
green, failure is bold red with readable red diagnostics, warnings and deferred
work are yellow, active work is cyan, headings are bold, progress details are
dimmed, and structured field labels are blue. The same palette applies across
all structured command families, transient and durable progress, terminal
failure rendering, deprecation warnings, and the closeout confirmation prompt.

Color is automatic only when the destination stream is a terminal. Stdout and
stderr are detected independently, `NO_COLOR` and `TERM=dumb` disable ANSI, and
redirected output remains byte-for-byte plain. JSON documents, JSONL logs,
followed text, SSH, and exec passthrough never enter the colorizer. This keeps
machine and byte-transparent contracts stable while making interactive state
easy to scan.

## Progress ownership

Move commands retain durable journal-backed command steps. Ordinary repository,
service, unit, resource, wipe, backup, job-retry, and instance operations use
transient timed steps around their exact execution boundaries; they do not
acquire transaction authority merely to share the renderer.

Progress is nested. A child host-agent, transfer, or verification step may
temporarily become the active TTY line, but completing it restores the parent
span and its original timer. Redirected output remains append-only and contains
no terminal control sequences. JSON suppresses all human progress.

An interactive active step is a live lease on operator attention. It appears
before the blocking operation begins and redraws its elapsed time once per
second even when Git, Nix evaluation, SSH, or agent polling has not produced a
new event. Polling heartbeats and transfer byte/entry progress enrich that same
line; they are not responsible for keeping it alive. Repository publication
emits start/completion events at its real validation, commit, local-retention or
push, and verification boundaries, so the durable command journal and terminal
cannot claim a later step only after opaque work has already finished.

Lifecycle success language describes the postcondition, not the command verb:

- `move` initializes a migration, holds the target, and verifies the warm seed;
  it never says that the service or traffic moved;
- `prepare` reports a verified checkpoint;
- `run` alone reports that traffic moved to the target; and
- `close` reports a closed migration, with the state summary naming the
  canonical endpoint.

The workflow summary labels source-to-target intent as `Move`, never `Route`.
`State` is the only traffic/authority statement. Generated `Next` commands
preserve `--local` whenever repository evidence or retained command steps show
local authority, preventing an operator from crossing journal/publication
authority modes between lifecycle commands.

## Stability and tests

Public JSON values remain unchanged by presentation. A structured failure emits
exactly one JSON document, including fleet partial failure and controller
forwarding paths. Pure renderer tests cover workflow, backup, job, fleet,
inspection, dry-run, and nested-progress behavior. Parser tests assign an
explicit contract to every public command family and reject global `--json` on
streams and passthroughs.

Use the supported shell for the authoritative Rust gate:

```console
nix develop .#abird-host-manager --command \
  cargo test -p abird-host-manager -- --test-threads=1
```
