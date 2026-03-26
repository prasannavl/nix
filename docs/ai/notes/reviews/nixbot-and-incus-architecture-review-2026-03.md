# nixbot & lib/incus.nix Architecture Review — 2026-03-27

Comprehensive design, architecture, correctness, and refactoring review.

## lib/incus.nix

### Architecture

Well-structured NixOS module with clear separation:

- **Type system** (lines 34-141): `deviceType` and `machineType` submodules
  define a clean declarative interface.
- **Pure helpers** (lines 143-305): Image resolution, config hashing, device
  partitioning — all pure Nix, well-factored.
- **Systemd services** (lines 306-1012): reconcile, settle, images, GC, and
  per-machine lifecycle services.

### Findings

#### Correctness / Bugs

1. **`instance_state_json` assigned but not used in settle on non-Running path**
   (line 487-493): The variable is initialized to `'{}'` then only assigned when
   status is `Running`, which is correct — the subsequent IP check reads it. No
   bug, but the initialization on line 487 could be moved inside the Running
   block to reduce scope.

2. **`incus list` for status check is O(n) per guest** (lines 370-375, 485-486):
   Each guest individually calls `incus list "$name" --format json`. For hosts
   with many containers this produces serial API calls. Could batch with a single
   `incus list --format json` up front.

3. **Settle SSH port check uses bash `/dev/tcp`** (lines 520-526): This works
   but is bash-specific and can hang if the port is filtered (not refused).
   The `timeout 5` wrapper prevents hangs. Acceptable.

4. **GC `delete-all` removes host dirs via `rm -rf`** (lines 999-1003): This is
   by design (per `removalPolicy`), but the jq query parsing device metadata
   from `user.*` config keys (lines 987-995) is complex. If the naming
   convention changes, the regex could silently stop matching. Consider a
   validation assertion.

5. **`mapfile` on empty JSON arrays** (lines 658, 672, 687): When the JSON
   array is empty, `mapfile` produces an array with one empty-string element.
   The loops guard with `[ -n "$dev" ]` or similar, but the `for dev in
   "${create_only_device_names[@]}"` at line 659 does NOT have such a guard —
   it iterates with an empty device name if the array is empty, causing
   `add_device_from_props` to receive an empty name. **This is a latent bug**
   when a machine has no create-only devices but the loop still runs once.
   Fix: add `[ -n "$dev" ] || continue` inside the create-only device loop.

6. **Disk device update is unconditionally `set` per property** (lines
   719-723): Every property on every existing disk device is set every
   activation, even if unchanged. This is idempotent but noisy. Minor.

#### Design / Refactoring Opportunities

7. **Duplicate `append_machine` / arg-parsing boilerplate**: The reconcile and
   settle helpers have nearly identical argument parsing (lines 320-351 vs
   418-453). Could factor into a shared fragment or a common wrapper script.

8. **Image fingerprint computation** (line 914): Uses `cat metadata rootfs |
   sha256sum` — this is correct for matching Incus's internal fingerprint
   calculation. Good.

9. **`incus-images` service uses full jq paths** (line 879 etc): Uses
   `${pkgs.jq}/bin/jq` in some places but `jq` (from `path`) in others within
   the same service. Inconsistent but not a bug since `jq` is in `path`.

10. **`configHash` includes `createOnlyDevices` but not `syncableDevices`**
    (line 176): This is intentional — disk device changes are synced in-place
    without recreate. The design correctly separates these concerns.

---

## pkgs/nixbot/nixbot.sh

### Architecture

A 6300-line Bash deploy orchestrator with well-defined phases:

- **Repo workspace**: worktree isolation, lock-based concurrency, dirty/staged
  overlay support.
- **Host selection**: DAG ordering with topological sort, dependency expansion,
  bastion-first prioritization, skip/optional deploy policies.
- **Build phase**: parallel builds with job slots.
- **Snapshot/Deploy/Rollback**: generation snapshots, wave-based deploy with
  rollback on failure, optional-host isolation.
- **Terraform phases**: multi-provider (Cloudflare R2, GCP GCS) with
  per-project backend resolution and secret auto-loading.
- **Bastion trigger**: remote execution via SSH forced commands with
  base64-encoded argv transport.

The architecture is solid for its scope. The wave/level-based deploy with
rollback, the proxy chain resolution, and the bootstrap key injection are all
well-thought-out.

### Findings

#### Correctness / Bugs

11. **`acquire_repo_root_lock` spins without timeout** (lines 1113-1115):
    `while ! mkdir ... ; do sleep 0.2; done` will spin forever if a stale lock
    exists (e.g., from a killed process). The PID file is written but never
    checked for liveness. **Should add a staleness check** — read the PID from
    the lock, check if it's still running, and break the lock if not.

12. **`run_deps_action` passes `$@` (original args) instead of
    `request_args`** (line 6271): `run_deps_action "$@"` uses the original
    `main()` arguments, not the possibly-rehydrated `request_args`. This means
    if args came from `SSH_ORIGINAL_COMMAND`, the runtime shell re-exec would
    get the wrong arguments. In practice `deps` is unlikely to be called via
    SSH forced command, but it's inconsistent with how other actions use
    `request_args`.

13. **`ensure_runtime_ready` also passes `$@`** (line 6311): Same issue — at
    the `main()` dispatch, `ensure_runtime_ready "$@"` is called with the
    original arguments, but if `hydrate_request_args_from_ssh_command` rewrote
    them, the re-exec would use the wrong args. This could cause the nix shell
    re-exec to fail to parse the action on the second pass.

14. **`is_ip_address` false positive for strings like `foo:bar`** (line 1970):
    The `*:*` pattern matches any string containing a colon, not just IPv6
    addresses. This could misidentify hostnames with colons (unlikely in
    practice but technically wrong).

15. **`build_remote_install_file_cmd` shell injection surface** (lines
    2252-2281): The heredoc interpolates `${remote_tmp}`, `${remote_dest}`,
    `${remote_dir}`, etc. as single-quoted strings inside the generated script.
    These values come from controlled internal paths (`/tmp/nixbot-*`,
    `/var/lib/nixbot/*`), so this is safe in practice. But if a
    hostname/path ever contained a single quote, the generated script would
    break. Consider using `printf '%q'` for the interpolated values.

16. **Signal handling gap**: `cleanup` is registered as EXIT trap (line 6254),
    but there's no explicit SIGINT/SIGTERM trap. The `set -E` from `set -Eeuo
    pipefail` ensures ERR trap inheritance, and Bash converts signals to
    non-zero exits which trigger EXIT. This works but means
    `terminate_background_jobs` may race with child signals.

#### Design / Refactoring Opportunities

17. **Script size**: At 6300+ lines, this is a large Bash script. The
    architecture is well-organized with clear section headers, but some
    sections could benefit from being split into sourced files:
    - Terraform logic (~400 lines) is self-contained.
    - SSH/proxy chain resolution (~300 lines) is self-contained.
    - Logging/summary helpers (~400 lines) are self-contained.
    This would improve maintainability without changing behavior.

18. **Repeated jq calls to `NIXBOT_HOSTS_JSON`**: Functions like
    `host_deploy_mode`, `host_skip_enabled`, `host_wait_seconds`,
    `host_parent_for`, `host_parent_resource_for` each invoke `jq` separately
    on the same JSON. In hot paths (wave loops), this spawns many subprocesses.
    Could pre-extract all host metadata into bash associative arrays during
    `init_deploy_settings`.

19. **Nameref convention is consistent**: The `_out_ref` / `_inout_ref` /
    `_in_ref` suffixes with function-specific prefixes are well-applied. Good.

20. **`wait -n` usage** (lines 3395, 3412): Correct for job-slot draining.
    Note that `wait -n` returns the exit status of the completed job, and the
    code correctly checks for signal exits.

21. **`run_with_combined_output`** referenced at line 3429 but not shown in
    the read sections. This is likely a small stderr-to-stdout combiner
    helper.

22. **Dry-run coverage is thorough**: Deploy, bootstrap injection, and age
    identity injection all check `DRY_RUN` before mutating. Good.

23. **`flake.nix` exports `build = run`** (line 21): The `build` package alias
    is identical to `run`/`default`. If this isn't used, remove it.

---

## Summary of Actionable Items

### Bugs to Fix

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 5 | Medium | `lib/incus.nix:659` | Create-only device loop iterates once on empty array |
| 11 | Medium | `nixbot.sh:1113` | Repo lock spins forever on stale lock |
| 12-13 | Low | `nixbot.sh:6271,6311` | `$@` vs `request_args` mismatch for SSH-hydrated args |

### Refactoring Suggestions (non-urgent)

| # | Impact | Location | Suggestion |
|---|--------|----------|------------|
| 2 | Perf | `lib/incus.nix:370,485` | Batch `incus list` in reconcile/settle |
| 7 | DRY | `lib/incus.nix:320-453` | Factor shared arg parsing for reconcile/settle |
| 17 | Maint | `nixbot.sh` | Consider splitting into sourced files |
| 18 | Perf | `nixbot.sh` | Pre-extract host metadata to avoid repeated jq |
