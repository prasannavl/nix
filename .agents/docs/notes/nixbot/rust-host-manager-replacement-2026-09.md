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
terminals update the active phase in place. Redirected output and journals get
stable lines. Phase completion includes elapsed time and the final summary uses
short per-host and per-project states.

Normal output is intentionally succinct. `--verbose` streams raw child output;
`--prefix-host-logs` attributes those lines when fan-out would otherwise be
ambiguous. GitHub Actions mode uses groups and annotations without ANSI color.
Machine-readable list/version/command results remain on stdout; progress and
diagnostics remain on stderr.

## Parity and validation

The Abird source implementation accounted for all 237 legacy characterization
tests: 219 were directly ported, 17 were superseded by the shared move-style
output contract, and one was superseded by the invocation-scoped SSH
control-master design. Pvl keeps those Rust tests and adds regression coverage
for its inventory extensions.

The landing gate requires Rust formatting, Clippy, tests, the host-manager
binary, the unchanged Bash Nixbot package/tests, and repository diff lint with
import from derivation disabled at both outer and nested Nix boundaries. It also
asserts that the installed host-manager output has no `bin/nixbot`.

The later cutover gate additionally enables the Rust compatibility package,
switches in-process move deployments to `fleet::runtime`, updates callers and
documentation, and removes the Bash/Python files. No live deployment is part of
either code-validation gate.
