# Draft design: Fleet build outcomes and actionable diagnostics

Status: **implemented checkpoint** — Nix SSH backend changed; not deployed.
Repository baseline: `c21c683be` (dirty staged tree preserved). Owner: @pvl.
Reviewed against the current native Nix build path on 2026-11-18.

## Observed problem

The November 15 commit `161587584` introduced `UnconfirmedBuild` and changed
`validate_remote_build_output` to classify _all_ non-successful SSH-client
attempts as unconfirmed, regardless of whether Nix has reported a deterministic
build error. Its `Display` prints the client status, not the captured stderr.
Tests assert this behavior.

The remote builder is `pvl-x2`, selected for `pvl-a1` and other targets. The
builder GC lease uses a dedicated SSH session; the realization uses
`BUILD_LEASE_SCRIPT` in `fleet/build_runtime.rs`, with `exec "$@"`. Because the
script replaces itself with Nix, the remote command emits no controller-owned
terminal receipt.

The default `ProgressTask` dashboard only admits curated `[copy]` / `[build]`
activity and lifecycle output. It drops ordinary Nix/Cargo `error:` lines; those
remain in diagnostics and the interactive verbose history. The final host
summary uses the generic `UnconfirmedBuild::Display` instead of this retained
error evidence.

`fleet/host_runtime.rs::observe_stream` also accumulates **all** child stdout
and stderr bytes in process memory, even while streaming them to the recorder. A
long `--build-logs` command can therefore grow memory with total log volume. The
raw `DiagnosticSink` already records the stream, so a bounded capture is
sufficient for outcome classification.

The November 17 `d3f4b5eb3` fix collects **activation** failure-unit
diagnostics, not build errors. The earlier interactive Errors view is not an
automatic failure summary.

The three prior fleet errors were definitively caused by the missing Oniguruma
pkg-config dependency in Voxtype ONNX. The _new_
`diag-23c68df07dec4ae0ac43f5a94f0ce78b` was not available inside the Dotlink L5
sandbox, so its underlying Nix error is **not known** from the progress tail
alone.

## Goals and invariants

1. Show meaningful failure evidence without `--verbose` or `--build-logs`.
2. Distinguish an **observed, completed Nix failure** from a lost result.
3. Never turn a disconnected SSH client into proof of remote settlement; never
   redispatch uncertain realization.
4. Retain the existing builder lease/epoch checks, closure identity validation,
   and closed-on-error deployment gates.
5. Make diagnostics safe, bounded, attributable, and useful in interactive,
   plain text, and CI output. Retain full per-command diagnostics separately.
6. Keep the mechanism reusable for native Nix remote build operations without
   adding an independent state store or changing the agent backend.

## Proposed contract

Distinguish the remote command's **result** from the controller's
**observation**. Conceptually:

```rust
enum RemoteBuildOutcome {
    Succeeded { closure: NixStorePath, receipt: BuildReceipt },
    Failed { exit: i32, receipt: BuildReceipt, diagnostics: FailureDigest },
    Unconfirmed { client: ClientObservation, diagnostics: FailureDigest },
}
```

A `BuildReceipt` is produced only by the trusted remote launcher **after its
child Nix process has returned**. It binds a protocol version, an invocation
nonce, builder/derivation identity, completion status, and the bounded stdout
path result. A client transport exit code is not itself a remote receipt. The
receipt proves the launcher observed the Nix process finish, **not** that every
possible daemon child has quiesced; no automatic realization retries follow a
failed receipt.

`Failed` means a **confirmed unsuccessful command**, not necessarily a compiler
error: the digest may distinguish a Nix derivation error, native build launch
error, or unknown child error. `Unconfirmed` can also carry a strong observed
Nix error excerpt, but must not claim remote settlement. An interrupted local
client can be shown as `interrupted · remote settlement unconfirmed` when
appropriate.

## Remote execution protocol

For the Nix SSH backend, replace the realization-mode `exec "$@"` with a minimal
process-owning wrapper:

1. Preserve the stable GC lease FD/lock and the existing SSH authority.
2. Run the same pinned `nix build --print-out-paths --no-link --fallback`.
   Stream Nix stderr live through the existing ProcessSink/DiagnosticSink.
3. Capture only the normally tiny stdout path result in a **bounded** private
   buffer. Keep child stdout distinct from the control channel.
4. After the Nix child has exited and its stdout is complete, emit **one final
   versioned, nonce-bound terminal result frame** over the launcher-owned stdout
   channel, including the Nix exit status and captured path. The wrapper must
   never `exec` the child.
5. Require a valid final frame bound to the submitted derivation before
   classifying a result as `Succeeded` or `Failed`. Missing, truncated,
   contradictory, duplicated or malformed frames remain `Unconfirmed`.

The stdout protocol boundary must not accept free-form build output as a forged
completion marker. The launcher frames the result, while child output is
separated; the authenticated SSH route supplies transport identity. Bound
buffers and protocol lengths. The dedicated GC lease heartbeat still owns its
own session; do not replace it with this result stream or broaden permissions.

No remote mutable journal is required for the initial design. If future
requirements need reconnect/settlement queries after an actual SSH loss, that is
a distinct durable-job capability, not a reason to infer a receipt from raw
stderr.

## Outcome rules

| Evidence                                                       | State                                | Further action                                       |
| -------------------------------------------------------------- | ------------------------------------ | ---------------------------------------------------- |
| Valid exit-0 receipt + one verified output path + stable lease | Succeeded                            | Continue acquisition                                 |
| Valid nonzero terminal receipt                                 | Failed                               | Show cause, stop dependent hosts; no automatic retry |
| SSH disconnected, killed, interrupted, or no valid receipt     | Unconfirmed                          | Show observations, preserve source and no-retry rule |
| SSH exit 1 + Nix error text but no receipt                     | Unconfirmed, with Nix-reported error | Show the error; do not assert settlement             |
| Exit 0, but output path invalid or receipt/path inconsistent   | Unconfirmed protocol result          | Stop; show validation error, never treat as success  |

Do not use `SSH Exit(1)` as a shortcut for failure or `SSH Exit(255)` as the
sole definition of a transport loss. Classification is based on the terminal
protocol receipt; the client exit code remains supporting evidence. Build
failure should remain a failure under builder lease revalidation rather than
being promoted to a successful result.

## Failure diagnostics and operator UI

Keep the current full raw stderr diagnostic files and the existing terminal-safe
redaction functions. Add one **bounded failure digest** in the
process-observation/presentation seam, shared by interactive, plain, and CI
renderers:

- Capture the original Nix error block and important underlying cause (for
  example, `Cannot build …voxtype-onnx.drv`, `exit code 101`, and
  `onig_sys: oniguruma.pc not found`), including nearby context.
- Prioritize meaningful `error:`, `Reason:`, `panicked at`, and
  `Last N log lines` over a trailing list of cascading store failures.
  Extraction is **display-only**, never proof of execution settlement.
- Cap the source tail/context, per-line length and aggregate output. Redact
  secrets and terminal escapes using the existing common presentation layer; do
  not dump unsanitized stderr into a host row.
- For long-running remote builds, replace unbounded retained `ProcessOutput`
  stderr with a **bounded** capture policy: small stdout path/protocol frame,
  ring of recent stderr plus relevant error clusters, and explicit truncation
  indicators. The full byte stream still goes to the existing diagnostic
  recorder. Preserve current full-capture behavior for unrelated short commands
  until their consumers are audited.
- Surface diagnostic-recorder write failures rather than silently advertising a
  log path that might be empty. Fall back to the retained bounded error digest
  when the recorder is unavailable.
- On a failed or unconfirmed build, show the top cause by default and the exact
  command diagnostics path. `--build-logs` and the live Logs view still show
  comprehensive streaming output on demand.
- Show the failing _derivation_ and the executing _builder_ separately from the
  target host. Avoid confusing `build pvl-a1` with `running on pvl-a1`.
- The default live row keeps current derivation, stage, and elapsed time, with
  bounded/low-frequency updates. No repeated multi-line Cargo-log spam or
  surprise interactive view switching.

Suggested presentations:

```text
✗ pvl-a1 · build failed on pvl-x2 (Nix exit 1)
  voxtype-onnx-1.2.2 · cargo build (101)
  onig_sys: oniguruma.pc not found
  diagnostics: …/commands/build-pvl-a1-via-pvl-x2.stderr.log
```

```text
? pvl-a1 · remote build result unconfirmed (SSH disconnected)
  Last observed: Nix reported voxtype-onnx build failed
  No remote completion receipt; realization was not retried
  diagnostics: …/commands/build-pvl-a1-via-pvl-x2.stderr.log
```

The phase remains `FAIL` for both, while the _host qualifier_ is `Failed(Build)`
for a confirmed failure and `Unconfirmed(Build)` only for lost or inconsistent
execution evidence. Phase counts then correctly distinguish `failed` versus
`unconfirmed`. Avoid counting unknown remote work as finished.

## Owning code surfaces

| Concern                                              | Primary location                                |
| ---------------------------------------------------- | ----------------------------------------------- |
| Launch, terminal protocol and evidence type          | `fleet/build_runtime.rs`                        |
| SSH transport and process stderr observation         | `fleet/host_runtime.rs`                         |
| Pure path/receipt validation                         | `fleet/build.rs`                                |
| Conservative lease and build orchestration           | `fleet/native.rs`, `fleet/build_lease.rs`       |
| Task and host certainty outcomes                     | `fleet/host_tasks.rs`, `fleet/orchestration.rs` |
| Bounded failure summaries and shared redaction       | `fleet/presentation.rs`                         |
| Default terminal, Errors view, noninteractive output | `progress.rs`                                   |

The result state is owned once by the build boundary and passed as typed data
through the existing task/progress system. Do not create a second outcome
classifier in the UI or re-parse logs to decide safety. Do not modify
activation/rollback or agent-backed build protocols in this Nix-only change.

## Qualification matrix

- Confirmed Nix failure (including Cargo exit 101) displays root cause and host
  `failed`, with no acquisition.
- Confirmed success requires one valid output path and stable builder
  lease/closure identity; no downgrade of current proof requirements.
- Client exit 1/255, signal, EOF, or cancellation **without** receipt:
  unconfirmed, shows last diagnostic, no redispatch.
- Interrupted local process with possible remote work retains uncertainty.
- stdout spoof, duplicated/broken/truncated receipt, wrong invocation nonce,
  wrong derivation ID, and missing/multiple output paths: fail closed, never
  promote to success.
- SSH connection lost after Nix completion but before receipt: unknown remotely,
  no automatic retry.
- Interactive dashboard, `--verbose`, `--build-logs`, plain terminal, and CI all
  render the same bounded error digest; full raw diagnostics remain separate.
- Very large or unterminated stderr lines stay memory-bounded; diagnostic
  recorder errors surface a warning rather than losing evidence silently.
- Parallel hosts never attribute one build's errors to another and retain
  Ctrl-C/lease-epoch guarantees.
- End-to-end fixture: Nix/ONNX Oniguruma failure (sanitized synthetic fixture)
  and a successful small build under the actual remote runner.

## Original implementation sequence

1. Add pure receipt/result parser and remote launcher tests, then wire the
   Nix-only SSH build mode.
2. Separate `Failed` and `Unconfirmed` at the typed build/task/host boundary and
   update tests which currently assert all `Exit(1)` attempts are unconfirmed.
3. Introduce one bounded, redacted diagnostic digest reused in dashboard and
   final reports; confirm no new raw-secret leakage.
4. Exercise remote failure and transport-loss fixtures and targeted cross-host
   fleet tests. Run full qualification before enabling a new result protocol in
   production.

## Implementation checkpoint (2026-11-18)

Implemented for the ordinary Nix/SSH build backend, not the separate owned-agent
runtime:

- `fleet/build_runtime.rs`: a versioned, nonce- and derivation-bound terminal
  frame from the existing lease-protected remote Bash launcher. Nix stderr
  continues streaming, while its tiny stdout path is captured separately and
  bounded before the launcher emits a receipt. Invalid, missing or conflicting
  frames remain unconfirmed. A valid nonzero receipt becomes typed
  `FailedBuild`, not `UnconfirmedBuild`.
- `fleet/host_runtime.rs`: remote build result validation uses that receipt;
  large build outputs are streamed to the existing recorder and progress
  reporter while in-memory retention stays bounded to an 8 KiB stdout and 128
  KiB stderr tail. Overlong stderr lines are chunked rather than accumulated
  without a bound. Non-build process capture remains unchanged.
- `fleet/presentation.rs` and `fleet/native.rs`: a bounded/redacted root-cause
  excerpt is automatically shown on build failure, with the executing builder
  and exact command diagnostic path in the phase error. Host summaries
  distinguish confirmed failed builds from unconfirmed remote results; the
  latter still warn that remote work may remain active and never retries
  realization.
- Test fixtures for real Bash receipt execution, malformed receipts, no-retry
  transport losses, bounded large output, native fleet transport and parallel
  builder lease behavior updated.

The fixture uses the same onig/Cargo error pattern previously hidden by the host
manager; this is a **diagnostic** regression test only. The later real Voxtype
build failure is deliberately not investigated or modified in this change.

Qualification: focused build-runtime and host-runtime test suites passed (29 and
106 tests). Native fleet integration passed 19 cases in one run; the 20th
disconnect/no-replay case passed independently (64.79 s) after the previous
connected test session stopped before reporting its result. Rustfmt and
`git diff --check` passed. The focused presentation unit test
`build_failure_digest_prefers_cause_over_cascading_nix_errors` passed after an
isolated rerun. No full NixOS system build, system activation, commit or push
performed.

## Review hardening checkpoint (2026-11-18)

- Launcher exits with the _same_ status as Nix **after** emitting the validated
  receipt. Command `.status`, host outcome and `FailedBuild` agree. Mismatched
  SSH exit and receipt remain unconfirmed; no retry.
- Remote helpers use deterministic `/run/current-system/sw/bin` tools.
- A ranked first-error excerpt survives even if later output fills the bounded
  stderr tail. This retention policy cannot change certainty.
- The UI checks recorder health and file existence before advertising a log
  path. Failed writes produce an explicit diagnostics warning.
- Development builds report their actual local executor. Root-cause ranking is a
  pure helper shared by capture and presentation.

Qualification: strict Clippy `-D warnings`, Rustfmt, 29 build-runtime tests, 108
host-runtime tests, 20 native-fleet tests and targeted presentation/recorder
tests passed. Full NixOS system build and remote fleet preparation are separate
qualification steps.

Additional qualification: all 626 non-ignored host-manager library tests passed.
The standalone `nix build .#abird-host-manager` advanced through Rust
compilation but the connected execution session ended without a Nix exit result
or realized store output. Do not count that package build as passed; repeat it
from a normal terminal before production activation.
