//! Consumer admission only: never invokes Nix, opens a store or submits work.
use std::path::Path;
use std::process::Command;

fn manager(root: &Path) -> std::path::PathBuf {
    let directory = root.join("libexec");
    std::fs::create_dir(&directory).unwrap();
    let program = directory.join("abird-host-manager");
    std::fs::copy(env!("CARGO_BIN_EXE_abird-host-manager"), &program).unwrap();
    program
}

fn command(program: &Path, root: &Path, nix: &Path) -> Command {
    let mut command = Command::new(program);
    command
        .env_clear()
        .env("PATH", "/no-external-programs")
        .env("HOME", root)
        .env("XDG_STATE_HOME", root.join("state"))
        .env("ABIRD_HOST_MANAGER_NIX", nix)
        .env("NIXBOT_HOST_LOCAL_LOCK_PATH", root.join("action-lock"))
        .env("NIXBOT_RUNTIME_WORK_ROOT", root.join("runtime"))
        .current_dir(root);
    command
}

fn rejected_before_recording(program: &Path, root: &Path, nix: &Path) {
    for action in ["build", "dev-build", "deploy"] {
        let output = command(program, root, nix)
            .args(["fleet", action, "--strategy=agent"])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty(), "no recorded run or submission");
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.contains("compatible installed native consumer adapter"),
            "{error}"
        );
        for path in ["state", "action-lock", "runtime", "nix-executed"] {
            assert!(!root.join(path).exists(), "unexpected effect: {path}");
        }
    }
}

#[test]
fn missing_consumer_adapter_rejects_before_run_lock_recording_or_submit() {
    let root = tempfile::tempdir().unwrap();
    let manager = manager(root.path());
    // Existing file, so rejection comes from missing adapter, not path lookup.
    let nix = root.path().join("nix");
    std::fs::write(&nix, "not an executable").unwrap();
    rejected_before_recording(&manager, root.path(), &nix);
    let output = command(&manager, root.path(), &nix)
        .arg("_owned-acquire-preflight")
        .arg(&nix)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert_eq!(output.stderr, b"owned native consumer preflight failed\n");
}

#[test]
#[ignore = "requires ABIRD_TEST_ACQUISITION_LIBRARY and ABIRD_TEST_ACQUISITION_NIX (ABI3/Nix 2.34.9)"]
fn exact_native_consumer_passes_and_foreign_program_rejects_before_effects() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let library = std::env::var_os("ABIRD_TEST_ACQUISITION_LIBRARY").unwrap();
    let nix = std::env::var_os("ABIRD_TEST_ACQUISITION_NIX").unwrap();
    let root = tempfile::tempdir().unwrap();
    let manager = manager(root.path());
    symlink(library, manager.with_file_name("libabird-owned-nix.so")).unwrap();
    // Compatible exact immutable program and symlink spelling both qualify.
    let alias = root.path().join("nix-alias");
    symlink(&nix, &alias).unwrap();
    for selected in [Path::new(&nix), alias.as_path()] {
        let output = command(&manager, root.path(), selected)
            .arg("_owned-acquire-preflight")
            .arg(selected)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(output.stdout, b"ready\n");
        assert!(output.stderr.is_empty());
    }
    let other = root.path().join("nix");
    std::fs::write(&other, "#!/bin/sh\ntouch nix-executed\n").unwrap();
    std::fs::set_permissions(&other, std::fs::Permissions::from_mode(0o755)).unwrap();
    rejected_before_recording(&manager, root.path(), &other);
}
