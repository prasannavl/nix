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
- `○` is a neutral, nonterminal row: `○ pending` before a task starts,
  `○ <stage> done` after one finishes, and `○ <stage> done, finalizing` while a
  detached activation or rollback settles;
- `◇` means work deliberately deferred to deployment or a dry-run check that was
  not executed;
- `⊘` means interrupted or cancelled work: a distinct terminal outcome, not a
  host failure, whose row keeps its bounded output tail; and
- `✗` means failure; and
- dry runs say that no changes will be made and never claim success.

Completion phrases are lowercase and consistent: running rows use the stage noun
(`build plan`, `build`, `snapshot`, `closure relay push`, `prefetch podman`,
`health check`) and completion rows append `done`. Every phase's terminal
success summary uses the same wording, such as `✓ build done`,
`✓ snapshot done`, `✓ acquire done`, `✓ deploy done`, and `✓ health done`.
Casing is scoped to the labels that collapse into a phase: phase titles and
isolated message sentences keep their natural casing, while task, step, and
skipped rows stay lowercase.

Durable agent submission is not completion. Job views derive their state from
the retained job record. Fleet output retains one row per host and one overall
failure result, including partial success. Reboot reports submission rather than
claiming that a host completed its reboot.

Inspection and dry-run paths open both workflow and backup state read-only. A
missing state root remains missing; `list` reports an empty collection instead
of creating manager state.

## Interactive color

Color reinforces the existing glyph and prose vocabulary; it never replaces it.
Interactive terminals use one restrained semantic palette: success is green,
failure is red with readable red diagnostics, warnings and deferred work are
yellow, active work is cyan, headings alone are bold, rolling progress details
are dimmed, neutral or skipped outcomes and completed-line metadata use nixbot
gray, and structured field labels are blue. Completed phase rows color only the
primary phase outcome; host summaries color successful status values while
skipped host lines remain wholly gray. Host names are the one non-semantic use
of color: each takes a stable identity color from the shared nine-color nixbot
host palette, hashed with FNV-1a, so parallel rows stay distinguishable while
the glyph and status word remain authoritative for state. The same palette
applies across all structured command families, transient and durable progress,
terminal failure rendering, deprecation warnings, and the closeout confirmation
prompt.

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

Fleet deployment phases keep the complete selected-host roster visible. Each
running host owns a bounded rolling tail of up to five safe semantic lines;
successful work collapses, while failed work retains its tail. The phase header
reports stage, wave (only when the phase has multiple waves), running slots
(`<running>/<concurrency>`), completed, and elapsed counts, and omits the
derivable pending count. Host rows use one lowercase stage vocabulary for every
task: the live row reads `● <stage> · task elapsed <t>`, and a task that
finishes before the host reaches its terminal outcome leaves
`○ <stage> done · <t>` instead of the stale running label. While a running step
declares a heartbeat, a live row stays plain `●` while it is producing output
and pulses `●`/`○` once it has been quiet for a few seconds; once a declared
heartbeat is overdue (twice its interval), the glyph turns warning and the row
reports `no heartbeat · <age>`. Activation and rollback keep their stage and
read `○ activation done, finalizing · <t>` while the detached unit settles.
Terminal tasks whose outcome carries no duration keep the last task's elapsed
time, so completion rows still report how long the host took. Stage labels drop
the redundant host column but keep transport builders and readiness parents as
detail, for example `build done via abird gondor ci` and
`parent reconcile done · gap3 gondor`. Output ownership is consistent by phase:

- build shows normalized Nix evaluation, realization, copy, and store events;
- snapshot shows parent-readiness lifecycle events and the captured generation;
- acquisition shows normalized closure transfer, admission, Podman prefetch, and
  AI-model prefetch events;
- deployment shows pre-switch events and follows the detached activation or
  rollback log while its target-local unit is alive; and
- health hides the collector wire format and publishes parsed per-attempt
  healthy, settling, or failure facts from Rust.

Every step's process output is governed by one presentation policy. Curated
operational output and activation lifecycle output pass through terminal
sanitization, whole-line secret redaction, and bounded phase-specific
allowlists. Machine protocols, activation result frames, identity-upload
contents, and control commands never reach human progress or retained human
failure tails. Identity uploads and installs appear only as their own step rows;
their raw streams remain available only in private diagnostic files. `--verbose`
independently shows sanitized and whole-line-redacted non-protocol subprocess
output; dashboard admission never controls whether verbose output is emitted.
Unknown default-mode output fails closed to a generic diagnostic pointer instead
of relying on error keywords. SSH key discovery and local closure copies are
attributed to the affected host instead of appearing as unrelated phase-level
chatter. Nix store events must contain one validated store-root basename, and
manually published SSH or health-operation lines pass a separate semantic
allowlist. Health details expose only validated user and systemd-unit
identifiers or a generic diagnostics pointer; decoded collector text is never
copied directly into the default host tail.

The activation log follower is observational rather than authoritative. If it
exits early, the observer continues bounded result polling and drains only new
complete log lines by ordinal; the target-side result frame alone determines
activation success or failure.

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
