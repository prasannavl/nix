//! Native coordinator + real subprocess transport boundary. The SSH fixture
//! substitutes target responses; installed target authority stays a VM gate.

use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::fleet::deploy::{BootEnvironment, GenerationSnapshot, SystemGeneration};
use crate::fleet::inventory::Host;
use crate::fleet::selection::{SelectionOptions, select};
use crate::test_support::write_executable;

const TEST: &str = "fleet::native::cancellation_tests::durable_cancel_joins_native_batch_before_rollback_and_never_dispatches_tail";
const MODE: &str = "ABIRD_TEST_NATIVE_CANCEL_MODE";

#[test]
fn durable_cancel_joins_native_batch_before_rollback_and_never_dispatches_tail() {
    if let Ok(mode) = std::env::var(MODE) {
        exercise(&mode);
        return;
    }
    for mode in ["activated", "optional-failed", "rejected", "pre-switch"] {
        // Short transport root, including under a deeply nested Nix TMPDIR.
        let directory = tempfile::Builder::new()
            .prefix("fc-")
            .tempdir_in("/tmp")
            .unwrap();
        write_executable(&directory.path().join("ssh"), SSH).unwrap();
        let mut paths = vec![directory.path().to_owned()];
        paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", TEST, "--nocapture"])
            .env(MODE, mode)
            .env("ABIRD_TEST_NATIVE_CANCEL_ROOT", directory.path())
            .env("NIXBOT_LOCAL_SELF_TARGET", "off")
            .env("PATH", std::env::join_paths(paths).unwrap())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{mode}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

fn exercise(mode: &str) {
    let root = PathBuf::from(std::env::var_os("ABIRD_TEST_NATIVE_CANCEL_ROOT").unwrap());
    let invocation =
        Invocation::parse_legacy(["deploy", "--strategy=agent", "--deploy-jobs=2", "--force"])
            .unwrap();
    let inventory = Inventory {
        hosts: ["a", "b", "c"]
            .into_iter()
            .enumerate()
            .map(|(index, host)| {
                (
                    host.to_owned(),
                    Host {
                        target: Some(format!("192.0.2.{}", index + 11)),
                        user: Some("root".to_owned()),
                        deploy: if mode == "optional-failed" && host == "a" {
                            DeployMode::Optional
                        } else {
                            DeployMode::Strict
                        },
                        ..Host::default()
                    },
                )
            })
            .collect(),
        ..Inventory::default()
    };
    let selection = select(&inventory, &SelectionOptions::default()).unwrap();
    assert_eq!(selection.waves, [vec!["a", "b", "c"]]);
    let new = NixStorePath::closure_output("/nix/store/aaaaaaaa-nixos-system-new").unwrap();
    let old = SystemGeneration::parse("/nix/store/bbbbbbbb-nixos-system-old").unwrap();
    let closures = selection
        .ordered
        .iter()
        .map(|host| (host.clone(), new.clone()))
        .collect::<BTreeMap<_, _>>();
    let durable_check = || match fs::read(root.join("cancel")) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
        Ok(_) => bail!("durable parent is cancelling"),
    };
    let guard = ForwardWorkGuard::new(&durable_check);
    let signal = super::super::signal::install().unwrap();
    let mut effects = NativeFleetEffects::with_owned_handoff(
        &invocation,
        Path::new("/unused-nix"),
        &root,
        &inventory,
        &selection,
        OwnedHandoff {
            closures: closures.clone(),
            boot: selection
                .ordered
                .iter()
                .map(|host| (host.clone(), BootEnvironment::Container))
                .collect(),
            builder: "a".to_owned(),
            cache: CacheSource::new("https://cache.invalid", Vec::<String>::new()).unwrap(),
            runtime: root.clone(),
        },
        &root.join("diagnostics"),
    )
    .unwrap()
    .with_forward_work(guard.clone())
    .unwrap();
    // Exercise the concrete Deploy phase with already acquired candidates and
    // original snapshots; no source, store, build or admission fixture layer.
    effects.closures = closures.clone();
    effects.candidate_leases = closures.clone();
    effects.acquired = closures;
    for host in &selection.ordered {
        effects
            .snapshots
            .insert(host.clone(), GenerationSnapshot::captured(old.clone()));
    }
    let deployed = effects.run_phase(Phase::Deploy);
    assert!(
        deployed.is_err(),
        "{deployed:?}; activated={:?}; successful={:?}; calls={}",
        effects.activated,
        effects.successful,
        fs::read_to_string(root.join("calls")).unwrap_or_default(),
    );
    assert!(
        effects.candidate_leases.is_empty(),
        "withdrawal must allow lease cleanup"
    );
    assert!(guard.check().is_err());
    let activated = match mode {
        "pre-switch" => BTreeSet::new(),
        "rejected" => BTreeSet::from(["b".to_owned()]),
        _ => BTreeSet::from(["a".to_owned(), "b".to_owned()]),
    };
    assert_eq!(effects.activated, activated);
    if mode == "optional-failed" {
        assert_eq!(effects.rollback_succeeded, BTreeSet::from(["a".to_owned()]));
        assert!(effects.successful.contains("b"));
    }
    effects.rollback_interrupted(Phase::Deploy).unwrap();
    assert_eq!(effects.rollback_succeeded, activated);
    assert!(effects.pending_rollback.is_empty());
    assert!(!signal.cancel_local() && !signal.force_remote());
    assert!(signal.interruption().is_none());

    let calls = fs::read_to_string(root.join("calls")).unwrap();
    // c's acquired root still needs cleanup, but no forward deploy work starts.
    assert!(calls.contains("lease-release:c"), "{calls}");
    assert!(
        calls
            .lines()
            .filter(|line| line.ends_with(":c"))
            .all(|line| { matches!(line, "preparation:c" | "lease-release:c") }),
        "{calls}"
    );
    for host in ["a", "b"] {
        let submissions = calls
            .lines()
            .filter(|line| *line == format!("rollback-submit:{host}"))
            .count();
        assert_eq!(
            submissions,
            usize::from(activated.contains(host)),
            "{calls}"
        );
    }
    if mode != "pre-switch" {
        // b deliberately completes after a publishes cancellation. Its receipt
        // must be joined/merged before the coordinator can roll it back.
        assert!(calls.find("cancel:a").unwrap() < calls.find("complete:b").unwrap());
        assert!(calls.find("complete:b").unwrap() < calls.find("rollback-submit:b").unwrap());
    } else {
        assert!(!calls.contains("activate-submit:"), "{calls}");
    }
    // Health-phase interruption must not redo any already successful rollback,
    // including the optional worker's rollback before the coordinator joined.
    effects.rollback_interrupted(Phase::Health).unwrap();
    assert!(effects.run_phase(Phase::Health).is_err());
    assert_eq!(fs::read_to_string(root.join("calls")).unwrap(), calls);
}

#[test]
fn durable_forward_guard_latches_read_failure_without_process_cancellation() {
    let failed = AtomicBool::new(true);
    let check = || {
        if failed.load(Ordering::Acquire) {
            bail!("cancel marker read failed");
        }
        Ok(())
    };
    let guard = ForwardWorkGuard::new(&check);
    let worker = guard.clone();
    std::thread::scope(|scope| {
        scope.spawn(|| assert!(worker.check().is_err()));
    });
    failed.store(false, Ordering::Release);
    assert!(
        guard
            .check()
            .unwrap_err()
            .to_string()
            .contains("cancel marker read failed")
    );
    assert!(guard.stopped());
}

const SSH: &str = r#"#!/bin/sh
set -eu
root=$ABIRD_TEST_NATIVE_CANCEL_ROOT
mode=$ABIRD_TEST_NATIVE_CANCEL_MODE
host=unknown
for arg in "$@"; do
    case "$arg" in
        root@192.0.2.11) host=a ;;
        root@192.0.2.12) host=b ;;
        root@192.0.2.13) host=c ;;
    esac
done
record() { printf '%s:%s\n' "$1" "$host" >> "$root/calls"; }
wait_for() {
    n=0
    until [ -f "$root/$1" ]; do
        n=$((n + 1))
        if [ "$n" -ge 1000 ]; then echo "fixture barrier timed out: $1" >&2; exit 92; fi
        sleep 0.01
    done
}
# HostRuntime sends a constant SSH argv and base64-framed stdin. Inspect that
# envelope without executing its commands; argv-only matching proves nothing.
payload=$(cat)
decoded=$(printf '%s\n' "$payload" | {
    framed=0
    while IFS= read -r line; do
        case "$line" in
            "done <<'NIXBOT_ARGV'") framed=1 ;;
            NIXBOT_ARGV) framed=0 ;;
            *) if [ "$framed" = 1 ]; then printf '%s' "$line" | base64 -d; printf '\n'; fi ;;
        esac
    done
})
case "$* $decoded" in
    *systemd-run*nixbot-rollback-to-configuration*)
        case "$decoded" in *bbbbbbbb-nixos-system-old*) ;; *) exit 93 ;; esac
        record rollback-submit
        ;;
    *nixbot-rollback-to-configuration*) record rollback-observe ;;
    *systemd-run*nixbot-switch-to-configuration*) record activate-submit ;;
    *nixbot-switch-to-configuration*)
        record observe
        : > "$root/observing-$host"
        wait_for observing-a
        wait_for observing-b
        if [ "$host" = a ]; then
            record cancel
            : > "$root/cancel"
        else
            wait_for cancel
        fi
        record complete
        if [ "$host" = a ] && { [ "$mode" = optional-failed ] || [ "$mode" = rejected ]; }; then
            admitted=1
            if [ "$mode" = rejected ]; then admitted=0; fi
            printf '%s\n' '--- abird-activation-result begin ---' \
                'OutcomeSource=marker' 'Result=exit-code' 'ExecMainStatus=1' "Admitted=$admitted" \
                '--- abird-activation-result end ---' >&2
            exit 1
        fi
        ;;
    *reset_system_failed_state*)
        record pre-switch
        if [ "$mode" = pre-switch ]; then
            : > "$root/preparing-$host"
            wait_for preparing-a
            wait_for preparing-b
            if [ "$host" = a ]; then : > "$root/cancel"; else wait_for cancel; fi
        fi
        ;;
    *nixbot-acquire-candidate-lease*) record lease-acquire ;;
    *nixbot-release-candidate-lease*) record lease-release ;;
    *) record preparation ;;
esac
"#;
