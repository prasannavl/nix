use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::Path;
use std::time::{Duration, Instant};

#[path = "../src/fleet/run_state.rs"]
mod run_state;

use run_state::{
    ActionMutex, CleanupGuarantee, CleanupOptions, CleanupStep, DirectoryLock, ProcessProbe,
    RetentionOutcome, RunState, RuntimeRootPreference, RuntimeRoots, StateLock,
    action_needs_local_mutex, cleanup_order, deploy_activation_attempt_unit_name,
    deploy_activation_unit_name, rollback_activation_unit_name,
};

fn roots(base: &Path) -> RuntimeRoots {
    RuntimeRoots {
        primary: base.join("primary/nixbot"),
        fallback: base.join("fallback/nixbot"),
        diagnostic_keep: base.join("kept/nixbot"),
    }
}

#[test]
fn allocation_is_private_unique_and_can_fall_back() {
    let temp = tempfile::tempdir().unwrap();
    let runtime_roots = roots(temp.path());
    let run = RunState::allocate_with_id(
        runtime_roots.clone(),
        "abc_123",
        RuntimeRootPreference::Fallback,
    )
    .unwrap();

    assert_eq!(
        run.layout().run_dir,
        runtime_roots.fallback.join("run-abc_123")
    );
    assert_eq!(
        run.layout().diagnostic_dir,
        runtime_roots.fallback.join("diag-abc_123")
    );
    assert_eq!(
        fs::metadata(&run.layout().run_dir)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&run.layout().diagnostic_dir)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert!(
        RunState::allocate_with_id(
            runtime_roots.clone(),
            "abc_123",
            RuntimeRootPreference::Fallback
        )
        .is_err(),
        "create_dir must make run IDs exclusive"
    );
    assert!(
        RunState::allocate_with_id(runtime_roots, "../escape", RuntimeRootPreference::Fallback)
            .is_err()
    );

    let auto_roots = roots(temp.path());
    let automatic = RunState::allocate(auto_roots.clone(), RuntimeRootPreference::Auto).unwrap();
    assert_eq!(
        automatic.layout().run_dir.parent(),
        Some(auto_roots.primary.as_path())
    );
    automatic.normal_cleanup(CleanupOptions::default()).unwrap();
}

#[test]
fn layout_matches_nixbot_phase_and_runtime_paths_and_rejects_unsafe_names() {
    let temp = tempfile::tempdir().unwrap();
    let run =
        RunState::allocate_with_id(roots(temp.path()), "paths", RuntimeRootPreference::Primary)
            .unwrap();
    let layout = run.layout();

    let build = layout.phase_item("build", "gap3", None).unwrap();
    assert_eq!(build.log, layout.diagnostic_dir.join("logs.build/gap3.log"));
    assert_eq!(
        build.status,
        layout.diagnostic_dir.join("status.build/gap3.rc")
    );
    assert_eq!(
        build.duration,
        layout.diagnostic_dir.join("status.build/gap3.duration")
    );
    assert_eq!(build.artifact_dir, layout.run_dir.join("artifacts.build"));

    let tofu = layout
        .phase_item("tf", "apply", Some("cloudflare-dns"))
        .unwrap();
    assert_eq!(
        tofu.log,
        layout
            .diagnostic_dir
            .join("logs.tf/apply.cloudflare-dns.log")
    );
    assert!(layout.phase_item("tf", "apply", None).is_err());
    assert!(layout.phase_item("build", "../gap3", None).is_err());
    assert!(layout.phase_item("build", "gap3\nforged", None).is_err());
}

#[test]
fn line_state_is_locked_persistent_deduplicated_and_cache_coherent() {
    let temp = tempfile::tempdir().unwrap();
    let run =
        RunState::allocate_with_id(roots(temp.path()), "lines", RuntimeRootPreference::Primary)
            .unwrap();
    let mut state = run.line_state("completed-hosts").unwrap();

    assert!(state.mark_new("gap1").unwrap());
    assert!(!state.mark_new("gap1").unwrap());
    state.mark("gap2").unwrap();
    assert!(state.contains("gap1").unwrap());
    state.clear("gap1").unwrap();
    state.mark("gap0").unwrap();
    assert!(!state.contains("gap1").unwrap());
    assert!(state.contains("gap2").unwrap());
    assert_eq!(fs::read_to_string(state.path()).unwrap(), "gap2\ngap0\n");
    assert!(!state.lock_path().exists());
    assert!(state.mark("bad\nline").is_err());
}

struct NeverAlive;

impl ProcessProbe for NeverAlive {
    fn is_alive(&self, _pid: u32) -> bool {
        false
    }
}

struct AlwaysAlive;

impl ProcessProbe for AlwaysAlive {
    fn is_alive(&self, _pid: u32) -> bool {
        true
    }
}

#[test]
fn state_lock_recovers_stale_owner_but_preserves_live_owner() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("state.lock");
    fs::create_dir(&path).unwrap();
    fs::write(path.join("pid"), "4242\n").unwrap();

    assert!(StateLock::try_acquire(&path, 99, &AlwaysAlive).is_err());
    assert_eq!(fs::read_to_string(path.join("pid")).unwrap(), "4242\n");

    let lock = StateLock::try_acquire(&path, 99, &NeverAlive).unwrap();
    assert_eq!(fs::read_to_string(path.join("pid")).unwrap(), "99\n");
    drop(lock);
    assert!(!path.exists());
}

#[test]
fn local_action_mutex_keeps_the_directory_inode_and_hands_off_on_drop() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("nixbot-host-local.lock.d");
    let first = ActionMutex::try_acquire(&path).unwrap().unwrap();
    let metadata = fs::metadata(&path).unwrap();

    assert_eq!(metadata.permissions().mode() & 0o777, 0o755);
    assert!(ActionMutex::try_acquire(&path).unwrap().is_none());
    drop(first);

    let second = ActionMutex::try_acquire(&path).unwrap().unwrap();
    assert_eq!(fs::metadata(&path).unwrap().ino(), metadata.ino());
    drop(second);
    let blocking = ActionMutex::acquire(&path).unwrap();
    assert_eq!(blocking.path(), path);
    drop(blocking);
    assert!(
        path.is_dir(),
        "release must not replace or unlink the lock inode"
    );

    assert!(action_needs_local_mutex("deploy"));
    assert!(action_needs_local_mutex("tf/cloudflare-dns"));
    assert!(!action_needs_local_mutex("list-hosts"));
    assert!(!action_needs_local_mutex("check-bootstrap"));
}

#[test]
fn repository_directory_lock_waits_for_live_owners_and_reaps_stale_owners() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("nixbot-worktree.lock");
    fs::create_dir(&path).unwrap();
    fs::write(path.join("pid"), "4242\n").unwrap();

    let started = Instant::now();
    let error = DirectoryLock::acquire(&path, 99, Duration::from_millis(20), &AlwaysAlive)
        .unwrap_err()
        .to_string();
    assert!(started.elapsed() >= Duration::from_millis(20));
    assert!(error.contains("held by pid 4242"), "{error}");
    assert_eq!(fs::read_to_string(path.join("pid")).unwrap(), "4242\n");

    let lock = DirectoryLock::acquire(&path, 99, Duration::ZERO, &NeverAlive).unwrap();
    assert_eq!(lock.path(), path);
    assert_eq!(fs::read_to_string(path.join("pid")).unwrap(), "99\n");
    drop(lock);
    assert!(!path.exists());
}

#[test]
fn registries_markers_and_units_are_stable_without_embedding_host_names() {
    let temp = tempfile::tempdir().unwrap();
    let run = RunState::allocate_with_id(
        roots(temp.path()),
        "unit.safe",
        RuntimeRootPreference::Primary,
    )
    .unwrap();
    let layout = run.layout();

    let active = layout.active_deploy("gap3.example");
    assert_eq!(active.contents, "gap3.example\n");
    assert_eq!(active.path.extension().unwrap(), "deploy");
    assert_eq!(active.path.file_stem().unwrap().len(), 64);
    assert_eq!(
        layout.deploy_job(321, "gap3.example").path,
        layout.run_dir.join("deploy-jobs/321.job")
    );
    assert!(
        layout
            .activation_marker("gap3.example")
            .file_name()
            .unwrap()
            .to_string_lossy()
            .ends_with(".activation")
    );
    assert!(
        layout
            .pre_switch_rejection_marker("gap3.example")
            .file_name()
            .unwrap()
            .to_string_lossy()
            .ends_with(".pre-switch-rejected")
    );

    let activation = deploy_activation_unit_name(layout.run_id(), "gap3.example").unwrap();
    assert_eq!(
        activation,
        "nixbot-switch-to-configuration-unit.safe-c168acf969a6096a"
    );
    assert_eq!(
        deploy_activation_attempt_unit_name(layout.run_id(), "gap3.example", 1).unwrap(),
        activation
    );
    assert_eq!(
        deploy_activation_attempt_unit_name(layout.run_id(), "gap3.example", 3).unwrap(),
        format!("{activation}-retry3")
    );
    assert_eq!(
        rollback_activation_unit_name(layout.run_id(), "gap3.example").unwrap(),
        "nixbot-rollback-to-configuration-unit.safe-c168acf969a6096a"
    );
}

#[test]
fn failure_retains_nonempty_diagnostics_but_always_removes_runtime_data() {
    let temp = tempfile::tempdir().unwrap();
    let roots = roots(temp.path());
    let run = RunState::allocate_with_id(roots.clone(), "failure", RuntimeRootPreference::Primary)
        .unwrap();
    let runtime = run.layout().run_dir.clone();
    fs::write(run.layout().run_dir.join("secret"), "do not retain").unwrap();
    fs::create_dir_all(run.layout().diagnostic_dir.join("logs.build")).unwrap();
    fs::write(
        run.layout().diagnostic_dir.join("logs.build/gap3.log"),
        "failed\n",
    )
    .unwrap();

    let report = run
        .normal_cleanup(CleanupOptions {
            succeeded: false,
            keep_diagnostics: false,
            keep_on_failure: true,
        })
        .unwrap();
    let RetentionOutcome::Retained(path) = report.diagnostics else {
        panic!("expected retained diagnostics")
    };
    assert_eq!(path, roots.diagnostic_keep.join("diag-failure"));
    assert!(path.join("logs.build/gap3.log").is_file());
    assert!(!runtime.exists());
}

#[test]
fn empty_diagnostics_are_discarded_even_when_retention_is_requested() {
    let temp = tempfile::tempdir().unwrap();
    let run =
        RunState::allocate_with_id(roots(temp.path()), "empty", RuntimeRootPreference::Primary)
            .unwrap();
    let diag = run.layout().diagnostic_dir.clone();
    fs::create_dir_all(diag.join("logs.build")).unwrap();

    let report = run
        .normal_cleanup(CleanupOptions {
            succeeded: false,
            keep_diagnostics: true,
            keep_on_failure: true,
        })
        .unwrap();
    assert_eq!(report.diagnostics, RetentionOutcome::DiscardedEmpty);
    assert!(!diag.exists());
}

#[test]
fn cleanup_continues_to_runtime_removal_after_diagnostic_failure() {
    let temp = tempfile::tempdir().unwrap();
    let roots = roots(temp.path());
    let run =
        RunState::allocate_with_id(roots.clone(), "best-effort", RuntimeRootPreference::Primary)
            .unwrap();
    let runtime = run.layout().run_dir.clone();
    fs::write(run.layout().diagnostic_dir.join("failure.log"), "failed\n").unwrap();
    fs::create_dir_all(roots.diagnostic_keep.parent().unwrap()).unwrap();
    fs::write(&roots.diagnostic_keep, "not a directory\n").unwrap();

    assert!(
        run.normal_cleanup(CleanupOptions {
            succeeded: false,
            keep_diagnostics: true,
            keep_on_failure: true,
        })
        .is_err()
    );
    assert!(!runtime.exists(), "later cleanup steps must still run");
}

#[test]
fn cleanup_never_follows_symlinks_inside_or_at_an_owned_tree() {
    let temp = tempfile::tempdir().unwrap();
    let roots = roots(temp.path());
    let run =
        RunState::allocate_with_id(roots.clone(), "links", RuntimeRootPreference::Primary).unwrap();
    let external = temp.path().join("external");
    fs::create_dir(&external).unwrap();
    fs::write(external.join("sentinel"), "keep").unwrap();
    symlink(&external, run.layout().run_dir.join("outside")).unwrap();
    run.normal_cleanup(CleanupOptions::default()).unwrap();
    assert_eq!(
        fs::read_to_string(external.join("sentinel")).unwrap(),
        "keep"
    );

    fs::create_dir_all(&roots.primary).unwrap();
    let linked_run = roots.primary.join("run-linked");
    symlink(&external, &linked_run).unwrap();
    let linked_diag = roots.primary.join("diag-linked");
    fs::create_dir(&linked_diag).unwrap();
    let adopted = RunState::adopt(roots, linked_run.clone(), linked_diag).unwrap();
    assert!(adopted.normal_cleanup(CleanupOptions::default()).is_err());
    assert!(linked_run.is_symlink());
    assert!(external.join("sentinel").is_file());
}

#[test]
fn cleanup_order_is_explicit_and_sigkill_reaping_is_not_claimed() {
    assert_eq!(
        cleanup_order(true),
        [
            CleanupStep::TerminateBackgroundJobs,
            CleanupStep::ReleaseHostLocalMutex,
            CleanupStep::RestoreTty,
            CleanupStep::EndLogGroups,
            CleanupStep::CleanupRepositoryWorktree,
            CleanupStep::ReleaseRepositoryRootLock,
            CleanupStep::RetainOrDiscardDiagnostics,
            CleanupStep::RemoveRuntimeDirectory,
            CleanupStep::RemoveEmptyRoots,
            CleanupStep::RestoreTty,
        ]
    );
    assert_eq!(
        CleanupGuarantee::current(),
        CleanupGuarantee::NormalExitOnly
    );
    assert!(!CleanupGuarantee::current().reaps_after_sigkill());
}
