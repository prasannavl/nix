# Lock-transfer test isolation

- The normal Nix pre-push suite failed twice at the final lock-release assertion
  in `descriptor_transfer_preserves_original_exclusion`; five isolated runs
  passed. Both failures reported 632 passed, one failed and two ignored.
- `CLOEXEC` does not prevent a concurrent fork from copying an open description.
  A disposable-descriptor probe confirmed that an inherited SCM_RIGHTS lock
  survives the parent's close until that child exits. A parallel test's
  fork-to-exec window can therefore invalidate an immediate-release assertion.
- Run the unchanged ownership assertions in a fresh, single-test subprocess,
  following the existing test convention. No production-code change, sleeps,
  retries, weaker assertions or global test serialization.
- Canonical host-manager formatting, lint and tests passed in both repositories
  with the normal parallel test schedule. The library suites reported 633 passed
  / two ignored in Nix and 624 passed / two ignored in Z; their remaining
  binary/integration/doc-test targets also passed. Existing ignored tests stayed
  ignored.
- A diagnostic strace run changed scheduling: the lock test passed, but a
  separate timing-sensitive helper timed out. That run is not acceptance
  evidence.
- No fleet operation, NixOS system build, deployment or VM qualification.
