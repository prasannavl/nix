# Native User Graph Legacy Manager Removal (2026-07)

## Outcome

The native `systemd.user` graph and durable host-agent holds fully replace the
legacy `systemd-user-manager` bridge. The obsolete module, helper, tests, and
dedicated documentation were removed after the native graph had become the only
production orchestration path.

Nixbot no longer:

- discovers or streams legacy dispatcher units;
- prints a post-deploy dispatcher report; or
- reads `/etc/systemd-user-manager/dispatchers/*.metadata` for health-check
  settling budgets.

The native Podman Compose control registry is now the sole source for
`timeoutReadySeconds` health settling.

## Removed Surfaces

- `lib/systemd-user-manager/**`
- `checks.*.lib-systemd-user-manager-helper`
- `checks.*.lib-systemd-user-manager-module`
- `docs/systemd-user-manager.md`
- the legacy canonical service notes
- nixbot's dispatcher report and metadata compatibility path

Historical plans and incident notes still mention the removed bridge when it is
necessary to explain older behavior. Those references are evidence, not active
configuration or compatibility support.

## Current Ownership

- NixOS and native `systemd.user` units own switch-time convergence.
- Each service user has one `<user>-managed.target` convergence root.
- Per-instance ready targets and the generated control registry own health
  reporting.
- Every backend must publish its resolved `timeoutReadySeconds` in that control
  registry. The timeout is health-settling metadata for the common native user
  graph, not Compose-helper metadata; omitting it for Quadlet makes Nixbot fail
  immediately when a valid post-deploy start is still converging.
- The host agent owns durable managed-root holds; the host manager sequences
  explicit release and activation across hosts.
- Nixbot observes native graph and registry state without submitting a separate
  service-user transaction.

## Validation

The removal must retain:

- passing nixbot tests and Bash syntax checks;
- passing remaining library checks;
- control-registry coverage proving Compose and Quadlet entries both retain
  their resolved readiness timeout;
- representative host evaluation with no generated legacy units; and
- a source scan showing no active code/configuration references outside
  historical documentation.
