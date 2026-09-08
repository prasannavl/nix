use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::{Path, PathBuf};

use abird_host_manager::fleet::bootstrap::{
    AgeDiscoveryMode, AgeIdentityPolicy, AuthorizedKeyAction, BootstrapCheckHost,
    BootstrapCheckObservation, BootstrapExecutor, BootstrapInstallAction, BootstrapKeyState,
    BootstrapReadiness, CheckBootstrapResult, FileMode, ForcedCommandInput,
    ForcedCommandObservation, ForcedCommandReadiness, HostAgeIdentityAction, HostAgeIdentityInput,
    IdentityMaterializationPlan, KnownHostsInput, KnownHostsSeed, PathInspector, PrimaryRoute,
    ProbeObservation, ScanAlgorithm, SecretPathError, SshHostKeyPolicy, SudoAdmission,
    TransportDecision, TransportInput, VisibilityPlan, age_identity_candidates,
    authorized_key_action, bootstrap_key_install_plan, build_forced_command_check,
    check_bootstrap_results, classify_forced_command_readiness, host_age_identity_action,
    host_age_identity_install_plan, known_hosts_plan, plan_identity_materialization,
    prepare_transport, resolve_key_source_path, sudo_admission, temporary_transport_failure,
};

#[derive(Default)]
struct FakePaths {
    files: BTreeSet<PathBuf>,
    canonical: BTreeMap<PathBuf, PathBuf>,
}

impl PathInspector for FakePaths {
    fn is_file(&self, path: &Path) -> bool {
        self.files.contains(path)
    }

    fn canonicalize(&self, path: &Path) -> Result<PathBuf, SecretPathError> {
        self.canonical
            .get(path)
            .cloned()
            .ok_or_else(|| SecretPathError::Canonicalize(path.to_path_buf()))
    }
}

#[test]
fn key_resolution_preserves_bash_precedence_and_config_parent_fallback() {
    let cwd = Path::new("/repo");
    let config = Path::new("/repo/hosts");
    let mut paths = FakePaths::default();
    paths.files.extend([
        PathBuf::from("/repo/local-key.age"),
        PathBuf::from("/repo/hosts/config-key.age"),
        PathBuf::from("/repo/hosts/../shared-key.age"),
    ]);
    paths.canonical.insert(
        PathBuf::from("/repo/local-key.age"),
        PathBuf::from("/canonical/local-key.age"),
    );

    assert_eq!(
        resolve_key_source_path("", cwd, Some(config), &paths).unwrap(),
        Path::new("")
    );
    assert_eq!(
        resolve_key_source_path("/absolute/key.age", cwd, Some(config), &paths).unwrap(),
        Path::new("/absolute/key.age")
    );
    assert_eq!(
        resolve_key_source_path("local-key.age", cwd, Some(config), &paths).unwrap(),
        Path::new("/canonical/local-key.age")
    );
    assert_eq!(
        resolve_key_source_path("config-key.age", cwd, Some(config), &paths).unwrap(),
        Path::new("/repo/hosts/config-key.age")
    );
    assert_eq!(
        resolve_key_source_path("shared-key.age", cwd, Some(config), &paths).unwrap(),
        Path::new("/repo/hosts/../shared-key.age")
    );
    assert_eq!(
        resolve_key_source_path("missing.age", cwd, Some(config), &paths).unwrap(),
        Path::new("/repo/hosts/../missing.age")
    );
}

#[test]
fn age_identity_discovery_is_stable_deduplicated_and_respects_explicitness() {
    let automatic = AgeIdentityPolicy {
        configured: PathBuf::from("/home/pvl/.ssh/id_ed25519"),
        configured_explicitly: false,
        discovery: AgeDiscoveryMode::Auto,
    };
    assert_eq!(
        age_identity_candidates(&automatic),
        [
            PathBuf::from("/home/pvl/.ssh/id_ed25519"),
            PathBuf::from("/var/lib/nixbot/.ssh/id_ed25519"),
            PathBuf::from("/var/lib/nixbot/.age/identity"),
        ]
    );

    let explicit = AgeIdentityPolicy {
        configured: PathBuf::from("/var/lib/nixbot/.age/identity"),
        configured_explicitly: true,
        discovery: AgeDiscoveryMode::Auto,
    };
    assert_eq!(
        age_identity_candidates(&explicit),
        [PathBuf::from("/var/lib/nixbot/.age/identity")]
    );

    let forced = AgeIdentityPolicy {
        discovery: AgeDiscoveryMode::On,
        ..explicit
    };
    assert_eq!(age_identity_candidates(&forced).len(), 2);

    let disabled = AgeIdentityPolicy {
        discovery: AgeDiscoveryMode::Off,
        ..forced
    };
    assert_eq!(
        age_identity_candidates(&disabled),
        [PathBuf::from("/var/lib/nixbot/.age/identity")]
    );
}

#[test]
fn identity_materialization_distinguishes_plain_missing_and_encrypted_sources() {
    assert_eq!(
        plan_identity_materialization(
            Path::new("/keys/plain"),
            true,
            false,
            &[],
            Path::new("/runtime/key.1"),
        )
        .unwrap(),
        IdentityMaterializationPlan::Plain {
            source: PathBuf::from("/keys/plain")
        }
    );
    assert_eq!(
        plan_identity_materialization(
            Path::new("/keys/plain"),
            true,
            true,
            &[],
            Path::new("/runtime/key.1"),
        ),
        Err(SecretPathError::EncryptedIdentityRequired(PathBuf::from(
            "/keys/plain"
        )))
    );
    assert_eq!(
        plan_identity_materialization(
            Path::new("/keys/missing.age"),
            false,
            false,
            &[],
            Path::new("/runtime/key.1"),
        )
        .unwrap(),
        IdentityMaterializationPlan::Missing {
            source: PathBuf::from("/keys/missing.age")
        }
    );

    let encrypted = plan_identity_materialization(
        Path::new("/keys/deploy.age"),
        true,
        true,
        &[
            PathBuf::from("/identity/first"),
            PathBuf::from("/identity/second"),
        ],
        Path::new("/runtime/key.1"),
    )
    .unwrap();
    assert!(matches!(
        encrypted,
        IdentityMaterializationPlan::AgeDecrypt {
            output_mode: FileMode(0o600),
            ..
        }
    ));
}

#[test]
fn configured_known_hosts_is_strict_and_never_scanned() {
    let plan = known_hosts_plan(&KnownHostsInput {
        node: "app".to_owned(),
        target_host: "10.0.0.5".to_owned(),
        configured_contents: Some("host ssh-ed25519 synthetic".to_owned()),
        proxy_chain: Vec::new(),
        proxy_command: None,
        output_file: PathBuf::from("/runtime/known_hosts.app"),
    });
    assert_eq!(
        plan.seed,
        KnownHostsSeed::Configured {
            contents: "host ssh-ed25519 synthetic".to_owned()
        }
    );
    assert_eq!(plan.mode, FileMode(0o600));
    assert_eq!(plan.host_key_policy, SshHostKeyPolicy::Strict);
    assert!(plan.scans.is_empty());
}

#[test]
fn direct_known_hosts_scans_ed25519_then_falls_back_to_any_key() {
    let plan = known_hosts_plan(&KnownHostsInput {
        node: "app".to_owned(),
        target_host: "10.0.0.5".to_owned(),
        configured_contents: None,
        proxy_chain: Vec::new(),
        proxy_command: None,
        output_file: PathBuf::from("/runtime/known_hosts.app"),
    });
    assert_eq!(plan.seed, KnownHostsSeed::Empty);
    assert_eq!(plan.host_key_policy, SshHostKeyPolicy::Strict);
    assert_eq!(plan.scans.len(), 2);
    assert_eq!(plan.scans[0].algorithm, ScanAlgorithm::Ed25519);
    assert_eq!(plan.scans[1].algorithm, ScanAlgorithm::Any);
    assert!(plan.scans[1].only_if_host_still_missing);
}

#[test]
fn proxied_known_hosts_uses_accept_new_and_scans_only_direct_first_hop() {
    let plan = known_hosts_plan(&KnownHostsInput {
        node: "app".to_owned(),
        target_host: "10.0.0.5".to_owned(),
        configured_contents: None,
        proxy_chain: vec![
            abird_host_manager::fleet::bootstrap::ProxyHop {
                target: "jump.example".to_owned(),
                has_proxy_command: false,
            },
            abird_host_manager::fleet::bootstrap::ProxyHop {
                target: "inside.example".to_owned(),
                has_proxy_command: false,
            },
        ],
        proxy_command: None,
        output_file: PathBuf::from("/runtime/known_hosts.app"),
    });
    assert_eq!(plan.host_key_policy, SshHostKeyPolicy::AcceptNew);
    assert!(plan.scans.iter().all(|scan| scan.host == "jump.example"));
    assert!(!plan.scans.iter().any(|scan| scan.host == "10.0.0.5"));

    let custom_proxy = known_hosts_plan(&KnownHostsInput {
        proxy_chain: Vec::new(),
        proxy_command: Some("cloudflared access ssh --hostname %h".to_owned()),
        ..KnownHostsInput {
            node: "app".to_owned(),
            target_host: "10.0.0.5".to_owned(),
            configured_contents: None,
            proxy_chain: Vec::new(),
            proxy_command: None,
            output_file: PathBuf::from("/runtime/known_hosts.app"),
        }
    });
    assert_eq!(custom_proxy.host_key_policy, SshHostKeyPolicy::AcceptNew);
    assert!(custom_proxy.scans.is_empty());
}

#[test]
fn temporary_transport_classification_matches_retry_boundary() {
    for message in [
        "Connection timed out",
        "Connection timed out during banner exchange",
        "No route to host",
        "Connection reset by peer",
        "Connection closed by remote host",
        "kex_exchange_identification: banner line",
        "stdio forwarding failed",
        "mux_client_request_session failed",
        "Broken pipe",
    ] {
        assert!(temporary_transport_failure(message), "{message}");
    }
    assert!(!temporary_transport_failure(
        "Permission denied (publickey)"
    ));
}

struct FakeExecutor {
    probes: VecDeque<ProbeObservation>,
    forced: VecDeque<ForcedCommandObservation>,
    install_result: Result<(), String>,
    calls: Vec<String>,
}

impl Default for FakeExecutor {
    fn default() -> Self {
        Self {
            probes: VecDeque::new(),
            forced: VecDeque::new(),
            install_result: Ok(()),
            calls: Vec::new(),
        }
    }
}

impl BootstrapExecutor for FakeExecutor {
    fn probe_primary(&mut self, route: PrimaryRoute) -> ProbeObservation {
        self.calls.push(format!("probe:{route:?}"));
        self.probes.pop_front().unwrap()
    }

    fn check_forced_command(&mut self) -> ForcedCommandObservation {
        self.calls.push("forced-command".to_owned());
        self.forced.pop_front().unwrap()
    }

    fn install_bootstrap_key(&mut self) -> Result<(), String> {
        self.calls.push("install-bootstrap".to_owned());
        self.install_result.clone()
    }
}

fn transport_input() -> TransportInput {
    TransportInput {
        node: "app".to_owned(),
        primary_target: "nixbot@10.0.0.5".to_owned(),
        operator_target: Some("ops@10.0.0.5".to_owned()),
        has_full_proxy_route: false,
        force_bootstrap: false,
        primary_only: false,
        bootstrap_key_configured: true,
        bootstrap_ready_cached: false,
    }
}

#[test]
fn transport_prefers_primary_then_full_proxy_before_bootstrap() {
    let mut executor = FakeExecutor {
        probes: VecDeque::from([
            ProbeObservation::failed(255, "Permission denied"),
            ProbeObservation::Reachable,
        ]),
        install_result: Ok(()),
        ..FakeExecutor::default()
    };
    let decision = prepare_transport(
        &TransportInput {
            has_full_proxy_route: true,
            ..transport_input()
        },
        &mut executor,
    )
    .unwrap();
    assert_eq!(
        decision,
        TransportDecision::Primary {
            route: PrimaryRoute::FullProxy
        }
    );
    assert_eq!(executor.calls, ["probe:Direct", "probe:FullProxy"]);
}

#[test]
fn temporary_primary_failure_delays_operator_fallback() {
    let mut executor = FakeExecutor {
        probes: VecDeque::from([ProbeObservation::failed(255, "Broken pipe")]),
        install_result: Ok(()),
        ..FakeExecutor::default()
    };
    assert_eq!(
        prepare_transport(&transport_input(), &mut executor).unwrap(),
        TransportDecision::RetryTemporaryTransport
    );
    assert_eq!(executor.calls, ["probe:Direct"]);
}

#[test]
fn forced_command_readiness_can_select_operator_without_key_reinstallation() {
    let mut executor = FakeExecutor {
        probes: VecDeque::from([ProbeObservation::failed(255, "Permission denied")]),
        forced: VecDeque::from([ForcedCommandObservation::Succeeded]),
        install_result: Ok(()),
        ..FakeExecutor::default()
    };
    assert_eq!(
        prepare_transport(&transport_input(), &mut executor).unwrap(),
        TransportDecision::OperatorFallback {
            target: "ops@10.0.0.5".to_owned(),
            readiness: BootstrapReadiness::ForcedCommand,
        }
    );
    assert_eq!(executor.calls, ["probe:Direct", "forced-command"]);
}

#[test]
fn injected_bootstrap_retries_primary_then_falls_back_to_operator() {
    let mut executor = FakeExecutor {
        probes: VecDeque::from([
            ProbeObservation::failed(255, "Permission denied"),
            ProbeObservation::failed(255, "Permission denied"),
        ]),
        forced: VecDeque::from([ForcedCommandObservation::Failed {
            output: "denied".to_owned(),
        }]),
        install_result: Ok(()),
        ..FakeExecutor::default()
    };
    assert_eq!(
        prepare_transport(&transport_input(), &mut executor).unwrap(),
        TransportDecision::OperatorFallback {
            target: "ops@10.0.0.5".to_owned(),
            readiness: BootstrapReadiness::Injected,
        }
    );
    assert_eq!(
        executor.calls,
        [
            "probe:Direct",
            "forced-command",
            "install-bootstrap",
            "probe:Direct"
        ]
    );
}

#[test]
fn forced_bootstrap_requires_operator_and_bypasses_primary_probe() {
    let mut executor = FakeExecutor {
        install_result: Ok(()),
        ..FakeExecutor::default()
    };
    let decision = prepare_transport(
        &TransportInput {
            force_bootstrap: true,
            ..transport_input()
        },
        &mut executor,
    )
    .unwrap();
    assert!(matches!(
        decision,
        TransportDecision::OperatorFallback { .. }
    ));
    assert_eq!(executor.calls, ["install-bootstrap"]);
}

#[test]
fn forced_command_plan_replaces_identity_and_forwards_safe_repo_config() {
    let plan = build_forced_command_check(&ForcedCommandInput {
        node: "app".to_owned(),
        ssh_target: "nixbot@10.0.0.5".to_owned(),
        ssh_options: vec![
            "-i".to_owned(),
            "deploy-key".to_owned(),
            "-o".to_owned(),
            "IdentitiesOnly=yes".to_owned(),
            "-o".to_owned(),
            "StrictHostKeyChecking=yes".to_owned(),
        ],
        override_identity: Some(PathBuf::from("/runtime/check-key")),
        sha: Some("abc123".to_owned()),
        config_path: Some(PathBuf::from("/repo/hosts/nixbot.nix")),
        repo_worktree: Some(PathBuf::from("/repo")),
        repo_root: Some(PathBuf::from("/mirror")),
    })
    .unwrap();
    assert_eq!(
        &plan.ssh_args[0..4],
        ["-i", "/runtime/check-key", "-o", "IdentitiesOnly=yes"]
    );
    assert!(!plan.ssh_args.iter().any(|arg| arg == "deploy-key"));
    assert!(
        plan.ssh_args
            .iter()
            .any(|arg| arg == "StrictHostKeyChecking=yes")
    );
    assert_eq!(
        plan.remote_command,
        [
            "/run/current-system/sw/bin/nixbot",
            "check-bootstrap",
            "--sha",
            "abc123",
            "--hosts",
            "app",
            "--config",
            "hosts/nixbot.nix",
        ]
    );
}

#[test]
fn forced_command_legacy_unsupported_action_still_proves_authentication() {
    assert_eq!(
        classify_forced_command_readiness(&ForcedCommandObservation::Succeeded),
        ForcedCommandReadiness::Ready
    );
    assert_eq!(
        classify_forced_command_readiness(&ForcedCommandObservation::Failed {
            output: "Unsupported action: check-bootstrap".to_owned(),
        }),
        ForcedCommandReadiness::LegacyAuthenticated
    );
    assert_eq!(
        classify_forced_command_readiness(&ForcedCommandObservation::Failed {
            output: "invalid action".to_owned(),
        }),
        ForcedCommandReadiness::LegacyAuthenticated
    );
}

#[test]
fn bootstrap_key_install_is_idempotent_private_and_always_ensures_authorization() {
    let plan = bootstrap_key_install_plan(Path::new("/runtime/bootstrap-key"));
    assert_eq!(
        plan.destination,
        Path::new("/var/lib/nixbot/.ssh/id_ed25519")
    );
    assert_eq!(
        plan.legacy_destination,
        Path::new("/var/lib/nixbot/.ssh/id_ed25519_legacy")
    );
    assert_eq!(plan.remote_base_mode, FileMode(0o755));
    assert_eq!(plan.directory_mode, FileMode(0o700));
    assert_eq!(plan.file_mode, FileMode(0o400));
    assert!(plan.backup_existing_to_legacy);

    assert_eq!(
        abird_host_manager::fleet::bootstrap::bootstrap_key_action(BootstrapKeyState::Matching),
        BootstrapInstallAction::EnsureAuthorizedOnly
    );
    assert_eq!(
        abird_host_manager::fleet::bootstrap::bootstrap_key_action(BootstrapKeyState::Different),
        BootstrapInstallAction::InstallAndEnsureAuthorized
    );
    assert_eq!(
        abird_host_manager::fleet::bootstrap::bootstrap_key_action(BootstrapKeyState::Unreachable),
        BootstrapInstallAction::FailUnreachable
    );

    let authorization = authorized_key_action(true, true);
    assert_eq!(authorization, AuthorizedKeyAction::AlreadyPresent);
    let authorization = authorized_key_action(true, false);
    assert!(matches!(
        authorization,
        AuthorizedKeyAction::PreserveAppendInstall {
            destination,
            mode: FileMode(0o444),
            owner,
            group,
        } if destination == Path::new("/etc/ssh/authorized_keys.d/nixbot")
            && owner == "root" && group == "root"
    ));
}

#[test]
fn host_age_identity_install_and_activation_visibility_match_remote_contract() {
    let install = host_age_identity_install_plan(Path::new("/runtime/age-key"), "sha256");
    assert_eq!(
        install.destination,
        Path::new("/var/lib/nixbot/.age/identity")
    );
    assert_eq!(install.remote_base_mode, FileMode(0o755));
    assert_eq!(install.directory_mode, FileMode(0o710));
    assert_eq!(install.file_mode, FileMode(0o440));
    assert_eq!(install.owner, "root");
    assert_eq!(install.group, "nixbot");

    assert_eq!(
        host_age_identity_action(&HostAgeIdentityInput {
            materialized_file: None,
            expected_sha256: None,
            remote_sha256: None,
        }),
        HostAgeIdentityAction::NotConfigured
    );
    assert_eq!(
        host_age_identity_action(&HostAgeIdentityInput {
            materialized_file: Some(PathBuf::from("/runtime/age-key")),
            expected_sha256: Some("sha256".to_owned()),
            remote_sha256: Some("sha256".to_owned()),
        }),
        HostAgeIdentityAction::AlreadyCurrent
    );

    let visibility = VisibilityPlan::host_age_identity("sha256");
    assert_eq!(visibility.maximum_attempts, 10);
    assert_eq!(visibility.retry_interval_seconds, 1);
    assert!(visibility.via_activation_context);
    assert!(
        visibility
            .command
            .contains("systemd-run --wait --pipe --quiet")
    );
}

#[test]
fn sudo_admission_is_root_or_passwordless_only() {
    assert_eq!(sudo_admission("root", None), SudoAdmission::Root);
    assert_eq!(
        sudo_admission("nixbot", Some(true)),
        SudoAdmission::Passwordless
    );
    assert_eq!(sudo_admission("ops", Some(false)), SudoAdmission::Denied);
    assert_eq!(
        abird_host_manager::fleet::bootstrap::sudo_probe_command(),
        ["sudo", "-n", "true"]
    );
}

#[test]
fn check_bootstrap_aggregates_no_key_missing_unreadable_and_valid_hosts() {
    let result = check_bootstrap_results(&[
        BootstrapCheckHost {
            host: "no-key".to_owned(),
            configured_key: None,
            observation: BootstrapCheckObservation::NotChecked,
        },
        BootstrapCheckHost {
            host: "valid".to_owned(),
            configured_key: Some(PathBuf::from("valid.age")),
            observation: BootstrapCheckObservation::Readable {
                fingerprint: "SHA256:valid".to_owned(),
            },
        },
        BootstrapCheckHost {
            host: "missing".to_owned(),
            configured_key: Some(PathBuf::from("missing.age")),
            observation: BootstrapCheckObservation::Missing {
                resolved: PathBuf::from("/keys/missing.age"),
            },
        },
        BootstrapCheckHost {
            host: "unreadable".to_owned(),
            configured_key: Some(PathBuf::from("bad.age")),
            observation: BootstrapCheckObservation::Unreadable {
                resolved: PathBuf::from("/keys/bad.age"),
            },
        },
        BootstrapCheckHost {
            host: "decrypt-failed".to_owned(),
            configured_key: Some(PathBuf::from("failed.age")),
            observation: BootstrapCheckObservation::MaterializationFailed,
        },
    ]);
    assert_eq!(
        result,
        CheckBootstrapResult {
            ok_hosts: vec!["no-key".to_owned(), "valid".to_owned()],
            failed_hosts: vec![
                "missing".to_owned(),
                "unreadable".to_owned(),
                "decrypt-failed".to_owned(),
            ],
            success: false,
        }
    );
}
