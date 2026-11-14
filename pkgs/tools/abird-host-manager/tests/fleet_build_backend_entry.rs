//! Actual manager entrypoint: private modes bypass the public renderer/config.

use std::process::{Command, Stdio};

#[test]
fn installed_worker_modes_fail_closed_without_public_initialization_or_payload_logs() {
    let marker = "PRIVATE-CALLER-PAYLOAD-MUST-NOT-BE-LOGGED";
    for (mode, diagnostic) in [
        ("_owned-capture", "owned caller capture failed"),
        ("_owned-source", "owned source operation failed"),
        ("_owned-request", "owned native request validation failed"),
        ("_owned-prepare", "owned preparation failed"),
        ("_owned-query", "owned native evaluation failed"),
        (
            "_owned-controller",
            "owned CI observation ended unconfirmed",
        ),
        ("_owned-unknown", "invalid owned worker mode"),
    ] {
        // Invalid arity in every mode, before stdin/placement/credentials.
        let output = Command::new(env!("CARGO_BIN_EXE_abird-host-manager"))
            .arg(mode)
            .args([marker; 6])
            .env_clear()
            .env("PATH", "/nonexistent")
            .env("HOME", "/nonexistent")
            .env("ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION", "1")
            .stdin(Stdio::null())
            .output()
            .expect("run manager binary");
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert_eq!(output.stderr, format!("{diagnostic}\n").as_bytes());
    }
}
