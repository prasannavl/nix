# Nixbot Rust Host Manager Replacement (2026-09)

`abird-host-manager fleet` contains the native Rust implementation of the
repository's fleet build, deploy, rollback, health, bootstrap, repository, CI,
cleanup, and OpenTofu workflows. It lands before cutover so it can be reviewed
and exercised without changing the active deployment path.

The packaged `nixbot`, NixOS module, workflows, move-command deployment adapter,
and `scripts/nixbot.sh` continue to use `pkgs/tools/nixbot/nixbot.sh`. Its
Python characterization suite remains active. The Rust compatibility binary
stays in the Cargo test graph but is removed from the installed host-manager
package, so it cannot shadow the current command. A later explicit cutover will
switch those callers and only then remove the Bash/Python implementation.

## Architecture

- `fleet::cli`, `inventory`, `selection`, and `plan` own pure input and graph
  contracts.
- Inventory capabilities derive one controller-then-registries control-plane
  unit. Selection places it last by default or first with
  `--control-plane-first`; hard predecessor edges always remain authoritative.
- `fleet::engine` and `orchestration` own bounded, stable-order execution and
  rollback decisions.
- Repository, workspace, CI, Terraform, build, deploy, bootstrap, health,
  transport, and host runtime effects have separate typed adapters.
- Remote commands use one invocation- and route-scoped SSH control socket.
  Activation and rollback retain independent supervised lifetimes.
- Remote builder outputs are protected by a crash-released, heartbeat-checked
  shared GC lease until each target has independently verified its closure.
  Lease loss reacquires protection, verifies the exact closure, and rebuilds it
  when GC won the unprotected interval. Nixbot creates no persistent builder
  roots and never owns garbage collection. Diagnostic streams are raw,
  uncolored, mode `0600`, and retained only when useful.
- Deploy workflows have a fleet-wide Acquire phase between Snapshot and Deploy.
  It distributes and target-leases every changed candidate, runs admitted image
  and model acquisition, and completes across all dependency waves before any
  activation starts. Required failure remains outside the rollback boundary and
  releases completed leases; optional failure excludes only that target after
  its lease cleanup is confirmed, while unresolved cleanup fails the barrier.
- The first `INT` or `TERM` waits for an admitted activation. Three signals
  within three seconds force remote cancellation. `HUP` terminates local work
  without claiming remote cancellation.
- Managed-user health convergence distinguishes structural failures, settling
  state, service failures, holds, deferred resources, and exhausted retry
  budgets. Pvl's exact `healthCheck.ignore` unit names are filtered at the
  system-unit failure boundary.
- The Pvl inventory keeps `config.deployDepsKey` with the default
  `nixbot.deployDependencies`; the native runtime evaluates the same key as the
  Bash implementation.

## Output contract

Fleet commands use the same progress renderer as move commands. Interactive
terminals keep the active phase above a rolling window of the ten most recent
child updates. The phase heading labels phase elapsed time, while child rows
label task elapsed time; a completed child must not look like the operation that
is still blocking the phase. Redirected output and journals retain the stable
line stream. Phase completion includes elapsed time and the final summary uses
short per-host and per-project states with total elapsed time.

Normal output is intentionally succinct. `--verbose` streams raw child output;
`--prefix-host-logs` attributes those lines when fan-out would otherwise be
ambiguous. GitHub Actions mode uses groups and annotations without ANSI color.
Machine-readable version and command results remain on stdout. The legacy
annotated host/group listings, progress, and diagnostics follow Bash's stderr
contract.

Interactive ANSI styling preserves the same hierarchy instead of turning color
into font weight. Bold is reserved for explicit phase and summary headings.
Active work, success, failure, warning, and label colors are normal weight;
elapsed metadata remains dim and raw verbose lines remain plain. Generic
messages never infer that their first line is a heading. Redirected, `NO_COLOR`,
`TERM=dumb`, GitHub, structured, diagnostic, and passthrough output remains
ANSI-free and byte-transparent.

## Shared progress and transport parity (September 27)

A shared-package canary exposed a route-classification bug in native known-host
preparation. When the target used a jump host whose own connection required
`ProxyCommand`, Rust attempted to run `ssh-keyscan` directly against that first
hop. Direct key scanning cannot traverse command-backed transports, so the scan
timed out before builder work could begin.

The native transport now has three explicit cases: scan a directly reachable
final target, scan a directly reachable first jump, or defer first contact to
SSH when either endpoint requires a proxy command. The latter uses a private,
route-scoped `known_hosts` file with `StrictHostKeyChecking=accept-new` through
the authenticated route; changed keys remain rejected. A regression fixture
models the command-backed first hop plus private builder and proves that direct
`ssh-keyscan` is never invoked.

A later shared-package canary exposed two independent remote-builder defects.
First, the invocation directory, verbose transport-directory prefix, and
host-readable socket filename produced a 110-byte OpenSSH `ControlPath`; Linux
Unix-domain socket paths must be shorter than 108 bytes. Native transport
directories now use a short `t-` prefix, control sockets use a fixed-length
digest of semantic route identity, and both construction boundaries reject
overlong paths before invoking SSH.

Second, parallel workers materialize encrypted builder keys under separate
private transport directories, but the shared lease coordinator compared route
debug output containing those temporary paths. Lease authority is now a typed
deterministic encoding of endpoint identity, identity presence, ordered proxy
topology and commands, local-hop flags, and host-key policy; ephemeral key paths
are excluded. A concurrent regression proves independently materialized keys
share one builder authority. Remote derivation-copy failures also retain their
decisive combined output in the default error chain instead of collapsing to a
status-only failure.

The next live candidate completed every build and then failed the first child
parent-readiness barrier with `Incus daemon is unavailable`. That helper message
also covers permission denial: a read-only probe proved `incus.service` was
active, root could query it, and the `nixbot` SSH user could not access the
Incus socket. Bash wraps parent readiness and every later target-control command
in passwordless sudo, while Rust had sent those commands directly as `nixbot`.
Native runtime execution now has an explicit root-command path. Non-root
endpoints use `/run/wrappers/bin/sudo -n` with the same pinned runtime `PATH` as
Bash; root endpoints avoid redundant sudo. Parent reconcile/settle, candidate
leases, generation admission, image/model prefetch, pre-switch preparation,
activation observation/cancellation/verification, rollback, and managed-health
collection use this boundary. Connectivity and remote-build work remain scoped
to the connection user, and argv stays base64-framed rather than reconstructed
as shell text.

The following shared-package canary crossed build, snapshot, artifact
acquisition, and generation admission, then failed before invoking
`switch-to-configuration`. The transient `systemd-run` service deliberately has
no ambient runtime `PATH`, but Rust generated
`run_admitted_target_switch env
NIXOS_INSTALL_BOOTLOADER=0 ...`. The external
`env` lookup therefore exited 127; rollback reused the same script and failed
identically. The runner now applies `NIXOS_INSTALL_BOOTLOADER=0` directly to the
shell function call, matching Bash Nixbot and preserving the explicit-path
activation contract. A regression runs both normal and legacy-rollback branches
with an unusable `PATH` and proves the activation environment reaches the target
switch.

That trace also exposed why host age-identity upload printed the complete remote
shell environment. The SSH request passed `bash`, `-c`, and the upload script as
separate remote arguments. OpenSSH reconstructed them as shell text, making
`set` the `bash -c` command and leaving the rest to the login shell. Upload now
sends one fully shell-quoted remote command while keeping identity bytes solely
on stdin. This removes the environment disclosure and retains private umask and
shell-safe destination validation.

Pvl then exposed a mixed-inventory progress contradiction: `gap3-gondor` has
`deploy = "skip"` and intentionally has no Pvl `nixbot.plans` attribute. Rust
still launched its plan evaluation, rendered the real missing-attribute exit as
a red failure, then independently masked the host as `skip` in the summary. A
successful native plan probe is now authoritative for this boundary. During
`run` or `deploy`, a deploy-skipped host absent from that probe is treated as an
external, unavailable plan: no per-host evaluation or build is scheduled and a
yellow `◇ ... · skipped` task is shown. Deploy-skipped hosts whose plans do
exist remain buildable, and explicit `build` plus strict or optional deployment
still fail on missing plans. This preserves the narrower deploy-skip contract
without pretending an external configuration failed.

The same incident showed Ctrl-C as ordinary red process and host failures.
Process completion now distinguishes success, failure, and interruption;
diagnostics record `interrupted`, active tasks and phases use the warning tone,
the workflow summary result is `interrupted`, and only unfinished hosts receive
that label. Completed closures remain `built`, deploy-skipped hosts remain
`skip`, and the signal exit status remains 129, 130, or 143 as appropriate.

The same shared parity refresh restores Bash-compatible host/group list
formatting and stderr routing, restricts health rollback eligibility to
structural failure, rolls back successful activations on forced cancellation,
aligns automatic build-plan concurrency and evaluation-cache admission, shares
exact SSH failure classification between build and deploy, and rejects empty
attached selectors. The Nix-pinned runtime wrapper and native three-root cleanup
remain intentional implementation differences.

These checks establish code parity, not live route acceptance. Repository-owned
inventory and authenticated deployment routes still require separate operator
validation before cutover.

The direct-main parity port kept all 17 changed package paths byte- and
mode-identical with Abird. The complete release suite, package build, formatter,
and warnings-denied Clippy gate pass. The first packaged release-test run hit a
transient `Broken pipe` in the unchanged
`deferred_job_polling_survives_a_transient_transport_drop` fixture; the isolated
release test, complete direct release suite, and packaged retry all passed.

The September 27 progress and incident follow-up exposes deploy phase position
(`1/5` through `5/5`) and records successful, failed, interrupted, and not-run
phases in the final summary. The default interactive dashboard keeps a bounded
ten-line window with at most two allowlisted progress lines per task. Failed
commands separately retain three terminal-safe lines so useful evidence is
printed after TTY, redirected, and GitHub Actions failures even if later
parallel activity evicted the live card. `--verbose` retains the original safe
line and full store path; potential credential-bearing lines are replaced
wholesale, and raw streams remain in private diagnostics. Remote-build labels
include both the workload host and builder, avoiding shared-builder task and
diagnostic collisions.

Two false failure paths were repaired. First, authoritative activation markers
do not carry systemd `ActiveState`; terminal `Result=success` or `exit-code`
with a numeric `ExecMainStatus` now settles without that fallback-only field,
and the observer rereads the final marker after consuming its log. This prevents
a successful activation or rollback from being reported as `Exit(255)`. Second,
the Pvl `pvl-vk` snapshot route failed because nested proxy commands used
`-W %h:%p` at every hop. OpenSSH expanded every placeholder to the final target,
causing `pvl-x2` to bypass `pvl-vlab`. The shared renderer now freezes each
explicit next-hop destination, including bracketed IPv6, matching Bash Nixbot's
generated proxy scripts.

Native run `4c4ea46816a544c1be95ba8dca1fcbd9` exposed a second proxy parity gap
during acquisition. `pvl-vlab-1` could not resolve the operator-facing `pvl-x2`
cache name, the local cache read succeeded, and Rust then rejected the relay
because the target had a proxy route. Local relays now use a single signed
cache-to-target `nix copy` with `NIX_SSHOPTS` rendered from the full prepared
route, without ControlMaster reuse. The target-side pull remains the fast path;
ordinary failure falls back once, signals stop, and classified transport loss
uses bounded retry. Relay command labels include the target to keep parallel
diagnostics distinct.

The next Gondor acceptance run completed activation and then found a failed
`abird-agent.service`. Retained pre-switch evidence proved the user unit was
already failed before activation. Read-only live inspection found
`Result=start-limit-hit`, five immediate exits, and the exact journal error
`controller database schema structure is incompatible`. The database recorded
schema digest `4e76306b...`, while the current controller expects `57337f52...`;
its mtime also predates the deployment. Snapshot and candidate generations use
the same controller binary, so generation rollback is neither eligible nor
causally useful. The unpublished controller-state policy requires a separately
authorized blank-state reset; the host-manager must preserve this service
failure instead of silently clearing it.

Health failures now trigger one bounded read-only diagnostic pass after final
classification. It covers at most three failed system or managed-user units,
records selected systemd result/exit/restart properties, and retains at most
three recent journal lines per unit. The decoded terminal report is control-
character safe, length bounded, and whole-line redacted for credential-like
content; raw protocol output remains in the private diagnostic directory.
Multiline failure evidence is indented consistently in plain terminals and
escaped for GitHub command syntax. The successful base64 health collector is
never misrepresented as a failed subprocess, and service failures remain
distinct from rollback-eligible structural failures.

## Pvl repository boundary

Pvl's evaluated inventory assigns both the controller and transfer-broker
capabilities to `pvl-x2`. Concrete host names, groups, builders, registries, and
routes remain inventory-owned and must not be embedded in the shared package
README.

Pvl keeps the placement and move inputs disabled by default because it has no
service migration capsule or multi-role placement topology. The shared
evaluator, admission check, and manager implementation are present, but
authoring a move requires Pvl-owned schema-2 placement state, a move directory,
and an eligible service migration contract. Consequently, the generic move and
cutover examples document the package contract rather than a currently
authorized Pvl operation.

This boundary is independent of the Nixbot-engine cutover: the packaged
`nixbot`, NixOS module, workflows, move-command deployment adapter, and
repository wrapper remain on Bash until a separate reviewed cutover.

## Parity and validation

Both repositories carry the same 306 shared runtime characterization tests. Pvl
adds one inventory identity test. Abird separately adds one repository identity
test that mechanically checks its source-owned
`.agents/plans/**/TEST-DISPOSITION.md` parity ledger. Keeping that assertion in
an Abird-only sibling leaves the shared test module byte-identical without
weakening the ledger gate.

The September 22 shared parity port added current-generation admission for
normal deployment and rollback, GitHub-token projection into Nix, build effects
during dry deploys, and explicit pre-switch rejection classification. It also
keeps Rust and Bash remote realizations aligned on `--fallback`. These changes
remain pre-cutover code: Bash Nixbot is still the active deployment engine.

The landing gate requires Rust formatting, Clippy, tests, the host-manager
binary, the active Bash Nixbot package/tests, and repository diff lint with
import from derivation disabled at both outer and nested Nix boundaries. It also
asserts that the installed host-manager output has no `bin/nixbot`.

The later cutover gate additionally enables the Rust compatibility package,
switches in-process move deployments to `fleet::runtime`, updates callers and
documentation, and removes the Bash/Python files. No live deployment is part of
either code-validation gate.
