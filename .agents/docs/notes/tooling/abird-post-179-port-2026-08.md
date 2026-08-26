# Abird Post-179 Port, 2026-08

## Scope

- Pvl baseline: `5659f7bb0098281b71fc85b5e0e7e2e4ef169208` on the primary
  `master` worktree.
- Previous audited Abird source tip: `17986f2a393a808907fcd304b498e640b5b0c39b`.
- Frozen and re-fetched Abird source tip:
  `05fe5cebfe55a66883925219ff7e207ab5970a2d`.
- Audit window: `17986f2a..05fe5ceb`, 11 commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Three parallel read-only reviews inspected every commit from frozen Git objects.
Relevant implementation was applied directly to the primary worktree after the
user rejected side-worktree landing. No commit, push, deployment, persistent
live mutation, or secret-key read occurred.

## Per-commit ledger

|  # | Commit     | Subject                                       | Final disposition                                                                                                                                                                                                                                               |
| -: | ---------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `d2c346b6` | `fix(nixbot): avoid self-cache copies`        | Already adopted by Pvl `2e1e662d`: both reusable Nixbot blobs and modes were exact. Pvl keeps its own incident and deploy notes.                                                                                                                                |
|  2 | `098138f8` | `fix(nixbot): relay unreachable caches`       | Already adopted by Pvl `7f1f3bbd`: both reusable blobs and modes were exact. Its proxy-selected relay rule is superseded at source tip by `aac59dc7`; the same-store and strict explicit-mode behavior remains.                                                 |
|  3 | `793a8431` | `test(flake): cover projected placements`     | Already adopted from Pvl `66164066`: generic placement propagation coverage was present. Pvl retains its generic whole-file fixture instead of Abird Gondor/Zulip topology assertions.                                                                          |
|  4 | `4cab54d6` | `docs(port): record Pvl parity audit`         | Skipped: Abird-owned reverse-port ledger, plan events, integration, publication, and repository geometry.                                                                                                                                                       |
|  5 | `12ff2855` | `docs(plans): record parity publication`      | Skipped: Abird-only plan publication provenance; all paths are absent from Pvl.                                                                                                                                                                                 |
|  6 | `aac59dc7` | `fix(nixbot): harden deploy routing`          | Cleanly ported: final Nixbot script and complete Python suite are byte-and-mode exact. Pvl adds the matching flake-output pointer and adapted controller dependency export.                                                                                     |
|  7 | `7ef8fba2` | `fix(host-manager): harden reconciliation`    | Adopted: shared phase projection, host-manager module/test, and Rust sources are exact; Pvl root/test/inventory wiring is adapted. Abird controller-host override wiring was skipped because Pvl has no enabled production host-manager or controller override. |
|  8 | `4f1ebc57` | `fix(quadlet): decouple health readiness`     | Cleanly ported: all six changed Podman implementation/test files are exact. A cumulative VM review found one unchanged stale source test and corrected it locally as described below.                                                                           |
|  9 | `dc09ed3d` | `docs(ops): record deploy recovery`           | Partially adopted: the shared Podman design paragraph is exact; Nixbot and host-control conclusions were adapted into Pvl notes. Abird Zulip recovery, topology, plan state, events, and fleet proof were skipped.                                              |
| 10 | `852c36b5` | `style: fix lint`                             | Skipped: formatting-only changes to excluded or locally adapted Abird documentation and plan events. Pvl formats its own Markdown.                                                                                                                              |
| 11 | `05fe5ceb` | `test(host-manager): bind endpoint resources` | Cleanly ported: the final exact `agent_adapter.rs` fixture binds distinct source and target resources so projected executor lookup covers the production child-transaction shape.                                                                               |

## Logical port units

1. Nixbot deploy routing and ordering:
   - preserve same-store offline recursive verification;
   - try every distinct target's signed cache first and use one bounded local
     relay fallback without inferring cache reachability from SSH proxy
     metadata;
   - preserve explicit `cache` and `local-copy` modes, signals, and shared trust
     context; and
   - merge evaluated projection dependencies into ordinary Nixbot inventory
     edges without letting `--ci-first` discard controller predecessors.
2. Projection-aware host control:
   - derive runtime hosts from resource endpoints and effect executors;
   - export validated controller deployment dependencies from the root flake;
   - share a typed controller-local inventory override;
   - authorize failed-job supersession only for explicit active projection IDs
     while always retaining `--execute`; and
   - route projected cutover and rollback through the exact endpoint resource's
     effect executor.
3. Quadlet health readiness:
   - compile Compose `CMD` healthchecks as injection-safe shell argv;
   - use `Notify=conmon` so container units remain restartable during
     application startup;
   - gate `service_healthy` dependencies in bounded `ExecStartPre` waiters; and
   - gate public readiness in the bounded verify service over the emitted health
     manifest.

Pvl keeps `phaseProjectionDirectory = null`, so the generic projection control
plane and dependency export are inert until Pvl deliberately owns projection
documents. Pvl's controller capability resolves uniquely to `pvl-x2`, and the
current exported dependency list is empty.

## Cumulative review correction

Abird tip `05fe5ceb` retains a pre-change provider-transition VM assertion that
expects `mixed-partial.service` itself to fail on an unhealthy application. That
contradicts the new ownership boundary: `Notify=conmon` makes the public service
start successfully, while `mixed-partial-ready.target` and
`mixed-partial-verify.service` own bounded health convergence.

Pvl corrects `lib/podman-compose/tests/quadlet-provider-transition.nix` to start
the ready target, prove the failed health gate leaves the public graph active
for restart recovery, then explicitly stop the public service and prove
containers, staging, network, and staged files unwind. The fixture uses a
five-second ready timeout. This is a deliberate Pvl-ahead shared-test divergence
that should be ported back to Abird before the next parity audit.

## Parity contract

At source tip `05fe5ceb`, 393 tracked paths are common under `lib/**` and
`pkgs/**`. After this port, 373 are byte-and-mode exact and there are no mode
differences. All 13 source-window files intended for exact landing are exact;
the two source-window adaptations are:

- `lib/flake/root.nix`: retain Pvl inputs, exports, nullable projection source,
  and host construction while adding controller dependency export.
- `lib/flake/tests/phase-projection.nix`: retain generic Pvl placement fixtures
  while adding runtime-host coverage.

The new twentieth difference is the provider-transition VM correction above. The
other 17 differences are established repository-owned flake/catalog, hardware,
image, installer, kernel, locale, Nix, stack, sudo, systemd, package
documentation, Cloudflare example documentation, NATS inventory, and generic
host-manager README surfaces recorded by the preceding port ledger.

No relevant source commit or logical unit remains unported from this window.

## Validation

- Bash syntax, Nix parse checks, Cargo formatting, direct Quadlet helper tests,
  and `git diff --check` passed.
- The repository-packaged Nixbot, flake projection, host-manager, Podman module,
  Quadlet conversion, generator lifecycle, provider transition, and systemd user
  lifecycle checks all built successfully. An ambient Python Nixbot run passed
  220 of 227 cases; seven unrelated health tests invoked the installed host
  agent and failed on its live state-lock permissions.
- The focused provider-transition VM passed against the corrected ready/verify
  ownership contract.
- `nix flake check --no-build` passed with import from derivation disabled,
  including all seven Pvl NixOS configurations.
- The repository diff lint passed from baseline `5659f7bb`, including all seven
  changed-host evaluations.
- The `pvl-a1`, `pvl-l5`, and `pvl-x2` system closures built successfully with
  import from derivation disabled.
