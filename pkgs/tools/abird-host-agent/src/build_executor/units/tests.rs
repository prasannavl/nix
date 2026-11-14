use super::*;
use std::io::Write;

fn sample() -> String {
    format!(
        "Id=nix-daemon.service\nLoadState=loaded\nActiveState=inactive\nSubState=dead\nInvocationID={}\nControlGroup=\nSlice={SLICE}\nRestart=no\nJob=0\nExecMainCode=1\nExecMainStatus=0\nResult=success\n",
        "a".repeat(32)
    )
}

#[test]
fn unit_identity_state_and_exit_are_strict_not_transport_inferences() {
    let sample = sample();
    let unit = Unit::decode(sample.as_bytes(), "nix-daemon.service", true).unwrap();
    assert!(unit.stopped());
    assert_eq!(unit.exit, Some(ClientExit::Success));
    assert!(
        Unit::decode(
            sample.replace("Job=0", "Job=").as_bytes(),
            "nix-daemon.service",
            true
        )
        .unwrap()
        .stopped()
    );
    assert!(
        Unit::decode(
            sample.replace("Job=0\n", "").as_bytes(),
            "nix-daemon.service",
            true
        )
        .is_err()
    );
    assert!(
        Unit::decode(
            sample.replace("Job=0", "Job=garbage").as_bytes(),
            "nix-daemon.service",
            true
        )
        .is_err()
    );
    for (old, new) in [
        ("loaded", "not-found"),
        ("loaded", "masked"),
        ("Restart=no", "Restart=always"),
        ("Slice=abird-build-owned.slice", "Slice=system.slice"),
        ("inactive", "unknown"),
        (
            "ControlGroup=",
            "ControlGroup=/abird.slice/abird-build.slice-other/worker",
        ),
        (
            "ControlGroup=",
            "ControlGroup=/abird.slice/abird-build.slice/../worker",
        ),
        ("ExecMainCode=1", "ExecMainCode=3"),
        ("Result=success", "Result=oom-kill"),
    ] {
        assert!(
            Unit::decode(
                sample.replace(old, new).as_bytes(),
                "nix-daemon.service",
                true
            )
            .is_err(),
            "{new}"
        );
    }
    assert!(Unit::decode(sample.as_bytes(), "foreign.service", true).is_err());
    assert!(
        Unit::decode(
            format!("{sample}Job=0\n").as_bytes(),
            "nix-daemon.service",
            true
        )
        .is_err()
    );
    assert!(Unit::decode(&vec![b'a'; MAX_BYTES + 1], "nix-daemon.service", true).is_err());
    let pending = sample.replace("Job=0", "Job=123 stop");
    assert!(
        !Unit::decode(pending.as_bytes(), "nix-daemon.service", true)
            .unwrap()
            .stopped()
    );
}

#[test]
fn workload_observation_requires_exact_unit_root_even_with_matching_identity() {
    let client = format!("abird-build-client@{}.service", "a".repeat(64));
    for name in ["nix-daemon.service", client.as_str()] {
        let sample = sample().replace("nix-daemon.service", name);
        let expected = format!("{RELATIVE}/{name}");
        for state in [
            "inactive",
            "failed",
            "active",
            "activating",
            "deactivating",
            "reloading",
        ] {
            let sample = sample.replace("ActiveState=inactive", &format!("ActiveState={state}"));
            let decode = |cgroup: &str| {
                Unit::decode(
                    sample
                        .replace("ControlGroup=", &format!("ControlGroup={cgroup}"))
                        .as_bytes(),
                    name,
                    true,
                )
            };
            assert!(decode(&expected).is_ok(), "{name} {state}");
            for foreign in [
                "/abird.slice/abird-build.slice".to_owned(),
                "/abird.slice/abird-build.slice/".to_owned(),
                "/abird.slice/abird-build.slice/other.service".to_owned(),
                format!(
                    "/abird.slice/abird-build.slice/abird-build-client@{}.service",
                    "b".repeat(64)
                ),
                format!("{expected}/builder"),
                format!("{expected}/"),
                format!("{expected}-other"),
                format!("/abird.slice/abird-build.slice//{name}"),
                format!("/abird.slice/abird-build.slice/./{name}"),
                format!("/abird.slice/abird-build.slice/other.service/../{name}"),
            ] {
                assert!(
                    decode(&foreign).is_err(),
                    "{name} {state} accepted {foreign}"
                );
            }
        }
    }
}

#[test]
fn zero_default_fields_and_collected_invocation_do_not_invent_client_success() {
    let sample = sample()
        .replace("ExecMainCode=1", "ExecMainCode=0")
        .replace(&"a".repeat(32), "");
    let unit = Unit::decode(sample.as_bytes(), "nix-daemon.service", true).unwrap();
    assert_eq!(unit.exit, None);
    assert_eq!(unit.invocation, None);
    let active = sample
        .replace("inactive", "active")
        .replace("SubState=dead", "SubState=running");
    // Empty invocation cannot identify a running process, even if other fields exist.
    assert!(Unit::decode(active.as_bytes(), "nix-daemon.service", true).is_err());
}

fn probe(mode: &str) -> Units {
    let exe = std::env::current_exe().unwrap();
    let mut units = Units::new(exe.clone(), Duration::from_millis(100)).unwrap();
    units.pending = Some(
        Command::new(exe)
            .args([
                "--exact",
                "build_executor::units::tests::worker",
                "--nocapture",
            ])
            .env("OB_UNIT_PROBE", mode)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .unwrap(),
    );
    units
}

#[test]
fn local_probe_reads_are_size_and_time_bounded() {
    let mut success = probe("success");
    assert!(
        String::from_utf8(success.capture(Instant::now() + success.timeout).unwrap())
            .unwrap()
            .contains("PROBE_OK")
    );
    assert!(success.pending.is_none());
    for mode in ["flood", "hang", "failure"] {
        let mut units = probe(mode);
        let start = Instant::now();
        let error = units.capture(Instant::now() + units.timeout).unwrap_err();
        assert_eq!(
            error.is::<ObservationUnavailable>(),
            mode != "flood",
            "{mode}"
        );
        assert!(start.elapsed() < Duration::from_secs(5));
        // Drop only affects the test's own unreaped process group.
    }
}

#[test]
fn retirement_queries_and_stop_share_the_original_cutoff_without_spawn() {
    let expired = Instant::now() - Duration::from_millis(1);
    let mut units = Units::new(
        PathBuf::from("/nonexistent-owned-systemctl"),
        Duration::from_secs(2),
    )
    .unwrap()
    .with_deadline(expired)
    .with_deadline(Instant::now() + Duration::from_secs(30));
    assert_eq!(units.deadline, Some(expired));
    let attempt = "a".repeat(64);
    assert_eq!(
        units.controller(&attempt).unwrap_err().to_string(),
        "systemd adapter lifetime expired"
    );
    assert_eq!(
        units
            .request_controller_stop(&attempt)
            .unwrap_err()
            .to_string(),
        "systemd adapter lifetime expired"
    );
    assert!(units.pending.is_none());
}

#[test]
fn worker() {
    match std::env::var("OB_UNIT_PROBE").as_deref() {
        Ok("success") => println!("PROBE_OK"),
        Ok("failure") => std::process::exit(7),
        Ok("flood") => {
            for _ in 0..1024 {
                std::io::stdout().write_all(&[b'x'; 1024]).unwrap();
            }
        }
        Ok("hang") => loop {
            std::thread::park_timeout(Duration::from_secs(1));
        },
        _ => {}
    }
}

#[test]
fn unresolved_probe_blocks_new_probes_without_blocking_the_caller() {
    let mut units = probe("hang");
    let pid = units.pending.as_ref().unwrap().id();
    assert!(
        units
            .run(&["show"])
            .unwrap_err()
            .is::<ObservationUnavailable>()
    );
    assert_eq!(units.pending.as_ref().unwrap().id(), pid);
    units.pending.as_mut().unwrap().kill().unwrap();
    units.pending.as_mut().unwrap().wait().unwrap();
    // The original child must be reaped before a new probe can start.
    units.systemctl = PathBuf::from("/nonexistent-owned-systemctl");
    let error = units.run(&["show"]).unwrap_err();
    assert!(!error.is::<ObservationUnavailable>());
    assert!(units.pending.is_none());
}

#[test]
fn client_exit_requires_exact_invocation_and_retained_finished_state() {
    let owner = Ownership {
        executor_version: 1,
        builder_id: "builder".into(),
        store_id: "store".into(),
        attempt_id: "a".repeat(64),
        pool_epoch: std::num::NonZeroU64::new(1).unwrap(),
        boot_id: "boot".into(),
    };
    let name = owner.unit_name().unwrap();
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "a".repeat(32),
    };
    let sample = sample().replace("nix-daemon.service", &name);
    let decode = |text: &str| Unit::decode(text.as_bytes(), &name, true).unwrap();
    let observed = decode(&sample)
        .observe_client(&owner, Some(&handle))
        .unwrap();
    assert_eq!(
        observed,
        ClientObservation::Exited {
            handle: handle.clone(),
            exit: ClientExit::Success
        }
    );
    let retained = sample
        .replace("ActiveState=inactive", "ActiveState=active")
        .replace("SubState=dead", "SubState=exited");
    assert_eq!(
        decode(&retained)
            .observe_client(&owner, Some(&handle))
            .unwrap(),
        observed
    );
    assert_eq!(
        decode(&sample).observe_client(&owner, None).unwrap(),
        ClientObservation::Lost
    );
    assert_eq!(
        decode(&sample.replace(&format!("InvocationID={}", "a".repeat(32)), "InvocationID="))
            .observe_client(&owner, Some(&handle))
            .unwrap(),
        ClientObservation::Lost
    );
    // Replace only the property, not the attempt/unit name.
    assert_eq!(
        decode(&sample.replace(
            &format!("InvocationID={}", "a".repeat(32)),
            &format!("InvocationID={}", "b".repeat(32))
        ))
        .observe_client(&owner, Some(&handle))
        .unwrap(),
        ClientObservation::Foreign
    );
    assert_eq!(
        decode(&sample.replace("Job=0", "Job=123 start"))
            .observe_client(&owner, Some(&handle))
            .unwrap(),
        ClientObservation::Pending
    );
    let running = retained
        .replace("SubState=exited", "SubState=running")
        .replace("ControlGroup=", &format!("ControlGroup={RELATIVE}/{name}"));
    assert_eq!(
        decode(&running)
            .observe_client(&owner, Some(&handle))
            .unwrap(),
        ClientObservation::Pending
    );
}

#[test]
fn template_definition_probes_keep_bound_paths_without_replacing_execution_instances() {
    let path = PathBuf::from("/nix/store/00000000000000000000000000000000-units/template.service");
    let owner = format!("abird-build-client@{}.service", "a".repeat(64));
    let mut expected = BTreeMap::from([
        ("abird-build-client@.service".to_owned(), vec![path.clone()]),
        ("abird-owned-fleet@.service".to_owned(), vec![path.clone()]),
        (owner.clone(), vec![path.clone()]),
        ("nix-daemon.service".to_owned(), vec![path.clone()]),
    ]);
    let queries = Units::definition_queries(&expected).unwrap();
    assert_eq!(queries.len(), expected.len());
    assert!(!queries.contains_key("abird-build-client@.service"));
    for name in [
        "abird-build-client@abird-owned-definition.service",
        "abird-owned-fleet@abird-owned-definition.service",
        owner.as_str(),
        "nix-daemon.service",
    ] {
        assert_eq!(queries[name], std::slice::from_ref(&path));
    }
    expected.insert(
        "abird-build-client@abird-owned-definition.service".into(),
        vec![path],
    );
    assert!(Units::definition_queries(&expected).is_err());
}
