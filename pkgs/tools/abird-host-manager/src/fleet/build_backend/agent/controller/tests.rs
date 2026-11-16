use super::*;
use crate::fleet::transport::{SshEndpoint, SshRoutePlan, TransportRole};
use abird_host_agent::build_executor::journal::Acceptance;
use abird_host_agent::build_executor::request::{AdmissionPolicy, Deadlines, StorageIdentity};
use abird_host_agent::build_executor::source_transport::Receipt;

mod remote_capture;

fn declaration() -> Description {
    Description {
        identity: StorageIdentity {
            authority_id: "authority".into(),
            builder_id: "ci".into(),
            store_id: "store".into(),
        },
        issuer: "operator".into(),
        policy: AdmissionPolicy {
            capacity_digest: "c".repeat(64),
            max_jobs: 1,
            max_cores: 2,
            submission_age_seconds: 60,
            future_skew_seconds: 2,
            replay_seconds: 120,
            deadlines: Deadlines {
                heartbeat_seconds: 2,
                stale_seconds: 6,
                owner_seconds: 12,
                queue_seconds: 60,
                runtime_seconds: 600,
                stop_grace_seconds: 3,
                stop_limit_seconds: 10,
                retention_seconds: 60,
            },
        },
    }
}

fn binding() -> Binding {
    let endpoint = SshEndpoint::new(
        "ci",
        "ci.example",
        "operator",
        22,
        TransportRole::Primary,
        None,
    )
    .unwrap();
    Binding {
        declaration: declaration(),
        controller: Peer {
            host_id: "controller".into(),
            fabric_id: "fleet".into(),
        },
        builder: Peer {
            host_id: "ci".into(),
            fabric_id: "fleet".into(),
        },
        repository_id: "repo".into(),
        nix: NixOptions {
            max_jobs: 1,
            cores: 2,
            substitute: true,
        },
        target: HostExecutionTarget {
            route: SshRoutePlan::direct(endpoint),
            cwd: "/native/source".into(),
            known_hosts_file: None,
            local: true,
            ssh_connect_timeout_seconds: 2,
            ssh_server_alive_interval_seconds: 1,
            ssh_server_alive_count_max: 1,
            remote_read_timeout_seconds: 2,
            control_master: None,
        },
    }
}

fn locations() -> Locations {
    Locations {
        build_flake: InputLocation::source(""),
        inventory: InputLocation::source("hosts/nixbot.nix"),
        overlay: None,
        repository_config: Some(InputLocation::source("config")),
        dependency_flake: InputLocation::source(""),
    }
}

fn invocation() -> Invocation {
    Invocation::parse_legacy([
        "build",
        "--strategy=agent",
        "--group=prod",
        "--hosts=-omitted",
        "--require-hosts=app",
        "--dirty-staged",
    ])
    .unwrap()
}

#[test]
fn native_preparation_preserves_maximum_for_inventory_validation() {
    let mut invocation = invocation();
    invocation.options.deploy_jobs_per_domain_max = Some(16);
    let projected = preparation_invocation(&invocation);
    assert_eq!(projected.options.deploy_jobs_per_domain_max, Some(16));
}

#[test]
fn installed_prepare_rejects_before_profile_or_signal_effects() {
    let invocation = Invocation::parse_legacy(["prepare", "--strategy=agent"]).unwrap();
    let error = run_installed(invocation).unwrap_err();
    assert!(error.to_string().contains("prepare is not supported"));
}

fn source() -> CapturedSource {
    let revision = CommitSha::parse("a".repeat(40)).unwrap();
    CapturedSource::new(
        revision.clone(),
        Some(StagedPatch {
            base: revision,
            bytes: b"diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n".to_vec(),
        }),
        BTreeMap::new(),
    )
    .unwrap()
}

fn submission() -> Submission {
    Submission::native(
        invocation(),
        "/native/source".into(),
        locations(),
        binding(),
        source(),
    )
    .unwrap()
}

#[test]
fn native_locations_freeze_external_context_and_overlay_absence() {
    let root = Path::new("/native/source");
    let mut context = InventoryContext {
        config: root.join("hosts/nixbot.nix"),
        overlay: None,
        repository_config: Some(root.join("config")),
        dependency_repository: root.join("nested"),
    };
    let captured = Locations::from_native(root, root, &context, &BTreeMap::new()).unwrap();
    assert_eq!(
        captured.inventory,
        InputLocation::source("hosts/nixbot.nix")
    );
    assert!(captured.overlay.is_none());
    assert_eq!(captured.dependency_flake, InputLocation::source("nested"));
    context.overlay = Some(root.join("hosts/nixbot.local.nix"));
    let overlay = InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: "e".repeat(64),
        },
        relative: "overlay.nix".into(),
    };
    let external = BTreeMap::from([(context.overlay.clone().unwrap(), overlay.clone())]);
    let captured = Locations::from_native(root, root, &context, &external).unwrap();
    assert_eq!(captured.overlay, Some(overlay));
    context.dependency_repository = "/other/repository".into();
    assert!(Locations::from_native(root, root, &context, &external).is_err());
}

#[test]
fn native_selectors_and_required_coverage_are_not_eagerly_expanded() {
    let invocation = invocation();
    assert_eq!(
        selection(&invocation),
        Selection::Fleet {
            groups: vec!["prod".into()],
            host: None,
            hosts: Some("-omitted".into()),
            nix_config: None,
            control_plane_first: false
        }
    );
    let roundtrip: Invocation =
        serde_json::from_slice(&serde_json::to_vec(&invocation).unwrap()).unwrap();
    assert_eq!(roundtrip, invocation);
    assert_eq!(roundtrip.options.required_hosts, ["app"]);
    // Explicit experimental agent resolves, but never enters the nix pipeline.
    assert_eq!(
        roundtrip.resolve_build_strategy().unwrap(),
        Some(abird_host_agent::build_executor::strategy::ExecutionStrategy::Agent)
    );
    assert!(roundtrip.require_nix_pipeline().is_err());
}

#[test]
fn native_material_does_not_normalize_absent_empty_or_wrong_base() {
    let revision = CommitSha::parse("a".repeat(40)).unwrap();
    let absent = CapturedSource::new(revision.clone(), None, BTreeMap::new()).unwrap();
    let empty = CapturedSource::new(
        revision.clone(),
        Some(StagedPatch {
            base: revision.clone(),
            bytes: vec![],
        }),
        BTreeMap::new(),
    )
    .unwrap();
    assert_ne!(absent.intent(), empty.intent());
    assert_eq!(empty.intent().patch_digest, Some(digest_bytes(b"")));
    assert!(
        CapturedSource::new(
            revision,
            Some(StagedPatch {
                base: CommitSha::parse("b".repeat(40)).unwrap(),
                bytes: vec![]
            }),
            BTreeMap::new()
        )
        .is_err()
    );
}

#[test]
fn native_context_and_installed_capacity_mismatches_fail_before_recording() {
    let mut bound = binding();
    bound.nix.cores = 3;
    assert!(
        Submission::native(
            invocation(),
            "/native/source".into(),
            locations(),
            bound,
            source()
        )
        .is_err()
    );
    let mut context = locations();
    context.overlay = Some(InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: "e".repeat(64),
        },
        relative: "overlay.nix".into(),
    });
    assert!(
        Submission::native(
            invocation(),
            "/native/source".into(),
            context,
            binding(),
            source()
        )
        .is_err()
    );
}

struct MetadataTransport {
    calls: Vec<&'static str>,
    declaration: Description,
    artifact: Option<Vec<u8>>,
    planning: Option<Vec<u8>>,
    acknowledged: Option<String>,
    consumer_state: Option<protocol::ConsumerState>,
    abandonment_state: Option<protocol::AbandonmentState>,
    finish_abandonment: bool,
    reject_abandonment_status: bool,
    lose_ack: bool,
}
impl MetadataTransport {
    fn new() -> Self {
        Self {
            calls: vec![],
            declaration: declaration(),
            artifact: None,
            planning: None,
            acknowledged: None,
            consumer_state: None,
            abandonment_state: None,
            finish_abandonment: false,
            reject_abandonment_status: false,
            lose_ack: false,
        }
    }
}
impl Transport for MetadataTransport {
    fn request(&mut self, _target: &HostExecutionTarget, request: &Request) -> Result<Response> {
        let reply = match &request.command {
            protocol::Command::Describe => {
                self.calls.push("describe");
                Reply::Description {
                    declaration: self.declaration.clone(),
                }
            }
            protocol::Command::Submit { request } => {
                self.calls.push("submit");
                Reply::Accepted {
                    acceptance: Acceptance {
                        attempt_id: request.attempt_id()?,
                        spec_digest: request.digest()?,
                        sequence: 1,
                    },
                }
            }
            protocol::Command::SubmitNative { request } => {
                self.calls.push("submit-native");
                Reply::Accepted {
                    acceptance: Acceptance {
                        attempt_id: request.attempt_id()?,
                        spec_digest: request.digest()?,
                        sequence: 1,
                    },
                }
            }
            protocol::Command::Status { .. } => {
                self.calls.push("status");
                Reply::Unconfirmed {
                    code: protocol::Unconfirmed::Unavailable,
                }
            }
            protocol::Command::Artifacts {
                attempt_id,
                artifact_digest,
                offset,
            } => {
                self.calls.push("artifact");
                let bytes = self.artifact.as_ref().context("test artifact missing")?;
                let start = *offset as usize;
                let end = (start + 8192).min(bytes.len());
                Reply::Artifacts {
                    page: abird_host_agent::build_executor::ArtifactPage {
                        attempt_id: attempt_id.clone(),
                        artifact_digest: artifact_digest.clone(),
                        projection_digest: digest_bytes(bytes),
                        offset: *offset,
                        total: bytes.len() as u64,
                        bytes: bytes[start..end].to_vec(),
                    },
                }
            }
            protocol::Command::Planning {
                attempt_id,
                artifact_digest,
                planning_digest,
                offset,
            } => {
                self.calls.push("planning");
                let bytes = self.planning.as_ref().context("test planning missing")?;
                let start = *offset as usize;
                let end = (start + 8192).min(bytes.len());
                Reply::Planning {
                    page: abird_host_agent::build_executor::ArtifactPage {
                        attempt_id: attempt_id.clone(),
                        artifact_digest: artifact_digest.clone(),
                        projection_digest: planning_digest.clone(),
                        offset: *offset,
                        total: bytes.len() as u64,
                        bytes: bytes[start..end].to_vec(),
                    },
                }
            }
            protocol::Command::AcknowledgeConsumer { receipt } => {
                self.calls.push("ack");
                let digest = receipt.digest()?;
                ensure!(
                    self.acknowledged.as_ref().is_none_or(|old| old == &digest),
                    "test acknowledgement changed"
                );
                self.acknowledged = Some(digest.clone());
                if std::mem::take(&mut self.lose_ack) {
                    anyhow::bail!("test lost ACK response");
                }
                Reply::ConsumerAcknowledged {
                    attempt_id: receipt.ownership.attempt_id.clone(),
                    receipt_digest: digest,
                }
            }
            protocol::Command::ConsumerStatus { attempt_id } => {
                self.calls.push("consumer-status");
                Reply::ConsumerStatus {
                    attempt_id: attempt_id.clone(),
                    state: self.consumer_state.clone(),
                }
            }
            protocol::Command::AbandonConsumer { abandonment } => {
                self.calls.push("abandon");
                ensure!(
                    self.acknowledged.is_none(),
                    "test abandonment conflicts with ACK"
                );
                let digest = abandonment.digest()?;
                if let Some(old) = &self.abandonment_state {
                    ensure!(old.abandonment_digest == digest, "test abandonment changed");
                } else {
                    self.abandonment_state = Some(protocol::AbandonmentState {
                        abandonment_digest: digest.clone(),
                        release_digest: None,
                        retired: false,
                    });
                }
                if std::mem::take(&mut self.lose_ack) {
                    anyhow::bail!("test lost abandonment response");
                }
                Reply::ConsumerAbandoned {
                    attempt_id: abandonment.ownership.attempt_id.clone(),
                    abandonment_digest: digest,
                }
            }
            protocol::Command::ConsumerAbandonmentStatus { attempt_id } => {
                self.calls.push("abandon-status");
                if self.reject_abandonment_status {
                    return Ok(Response {
                        version: protocol::VERSION,
                        reply: Reply::Rejected {
                            code: protocol::Rejection::NotFound,
                        },
                    });
                }
                // Before acceptance, the real status reply is an explicit None.
                // Retirement may finish an existing statement, never create one.
                if self.finish_abandonment
                    && let Some(state) = self.abandonment_state.as_mut()
                {
                    state.release_digest = Some("8".repeat(64));
                    state.retired = true;
                }
                Reply::ConsumerAbandonmentStatus {
                    attempt_id: attempt_id.clone(),
                    state: self.abandonment_state.clone(),
                }
            }
            _ => anyhow::bail!("unexpected test transport command"),
        };
        Ok(Response {
            version: protocol::VERSION,
            reply,
        })
    }
    fn inputs(
        &mut self,
        _target: &HostExecutionTarget,
        _request: &BuildRequest,
        _bytes: &[u8],
    ) -> Result<Option<Receipt>> {
        anyhow::bail!("unconfirmed status cannot deliver source")
    }
}

#[test]
fn description_never_falls_back_or_confers_execution_permission() {
    let mut transport = MetadataTransport::new();
    assert_eq!(
        describe(&binding().target, &mut transport).unwrap(),
        declaration()
    );
    transport.declaration.identity.builder_id = "other".into();
    assert!(describe(&binding().target, &mut transport).is_err());
    assert_eq!(transport.calls, ["describe", "describe"]);
}

#[test]
fn durable_native_parent_survives_fresh_process_without_dispatch_replay() {
    let directory = tempfile::tempdir().unwrap();
    for operation in [
        "record",
        "reopen",
        "replacement",
        "early",
        "early-reopen",
        "service",
        "delivery",
        "consumer",
        "consumer-reopen",
        "consumer-replaced",
        "consumer-retire",
        "consumer-uncertain",
        "consumer-expired",
        "consumer-cancel",
        "consumer-planning",
        "consumer-planning-reopen",
        "consumer-planning-replaced",
        "consumer-planning-uncertain",
        "consumer-acquisition-preflight",
        "consumer-acquisition-crash",
        "consumer-acquisition-reopen",
        "consumer-acquisition-recorded",
        "consumer-acquisition-expired",
        "consumer-acquisition-cancelled",
        "consumer-acquisition-import-crash",
        "consumer-acquisition-import-reopen",
        "consumer-acquisition-import-retry",
        "consumer-acquisition-import-discard",
        "consumer-acquisition-helper-fence",
        "consumer-acquisition-abandonment",
        "consumer-acquisition-retire-ack",
        "remote-capture",
        "repository-record",
        "repository-reopen",
    ] {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "fleet::build_backend::agent::controller::tests::durable_parent_process",
                "--ignored",
                "--nocapture",
            ])
            .env("ABIRD_OWNED_PARENT_TEST", operation)
            .env("ABIRD_OWNED_PARENT_RECEIPT", directory.path())
            .env("XDG_STATE_HOME", directory.path().join("state"))
            .env(
                "ABIRD_OWNED_TEST_ROOTS",
                directory
                    .path()
                    .join(if operation.starts_with("consumer-acquisition") {
                        "acquisition-gcroots"
                    } else {
                        "gcroots"
                    }),
            )
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{operation}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

// Child-process fixture, not an additional canonical acceptance or remote-settlement test.
#[test]
#[ignore = "invoked by the fresh-process parent test with a private XDG namespace"]
fn durable_parent_process() {
    let operation = std::env::var("ABIRD_OWNED_PARENT_TEST").unwrap();
    let receipt = PathBuf::from(std::env::var_os("ABIRD_OWNED_PARENT_RECEIPT").unwrap());
    let mut transport = MetadataTransport::new();
    if operation.starts_with("repository-") {
        repository_process(&operation, &receipt);
    } else if operation == "remote-capture" {
        remote_capture::run(&receipt);
    } else if operation.starts_with("consumer") {
        consumer_process(&operation, &receipt, &mut transport);
    } else if operation == "delivery" {
        use abird_host_agent::build_executor::source_transport::InputState;
        let mut controller = submission().record().unwrap();
        controller.submit(&mut transport).unwrap();
        let attempt = controller
            .run
            .manifest()
            .children
            .keys()
            .next()
            .unwrap()
            .clone();
        let child = &controller.run.manifest().children[&attempt];
        let acceptance = Acceptance {
            attempt_id: attempt.clone(),
            spec_digest: child.request.digest().unwrap(),
            sequence: 1,
        };
        let owner = abird_host_agent::build_executor::Ownership {
            executor_version: 1,
            attempt_id: attempt.clone(),
            builder_id: "ci".into(),
            store_id: "store".into(),
            boot_id: "boot".into(),
            pool_epoch: std::num::NonZeroU64::new(1).unwrap(),
        };
        let status = |input: InputState| Response {
            version: protocol::VERSION,
            reply: Reply::Status {
                snapshot: Box::new(protocol::Snapshot::Live {
                    pool: abird_host_agent::build_executor::PoolHealth::Owned,
                    acceptance: acceptance.clone(),
                    phase: abird_host_agent::build_executor::Phase::Running,
                    prepared_digest: None,
                    input: Some(input),
                    outcome: None,
                    ownership: Some(owner.clone()),
                    accepted_at: 1,
                    renewed_at: 1,
                    reserved_at: Some(1),
                    settled_at: None,
                }),
            },
        };
        // No event-page replay: status carries the recorded delivery phase even
        // after InputReady/InputsReceived have rotated out of bounded history.
        controller
            .run
            .observe(&attempt, status(InputState::Ready))
            .unwrap();
        let bytes = controller.run.retained_material(&attempt).unwrap().unwrap();
        controller.run.claim_inputs(&attempt, &bytes).unwrap();
        let digest = digest_bytes(&bytes);
        controller
            .run
            .observe(
                &attempt,
                status(InputState::Received {
                    digest: digest.clone(),
                }),
            )
            .unwrap();
        let id = controller.run_id().to_owned();
        drop(controller);
        let mut reopened = Controller::open(&id).unwrap();
        assert!(reopened.run.claim_inputs(&attempt, &bytes).is_err());
        assert!(
            reopened
                .run
                .observe(&attempt, status(InputState::Ready))
                .is_err()
        );
        let manifest = Run::inspect(&id).unwrap();
        let private = serde_json::to_value(&manifest.children[&attempt]).unwrap();
        assert_eq!(private["input_received"], digest);
        assert_eq!(transport.calls, ["submit"]);
    } else if operation == "service" {
        let pending = PendingCapture {
            invocation: invocation(),
            cwd: receipt.join("absent-service-source"),
            bootstrap: None,
            environment: None,
        };
        let mut binding = binding();
        binding.controller = binding.builder.clone();
        let mut controller = admit_service(pending, binding).unwrap();
        let attempt = controller
            .run
            .manifest()
            .children
            .keys()
            .next()
            .unwrap()
            .clone();
        let spec = controller.run.manifest().children[&attempt]
            .request
            .digest()
            .unwrap();
        controller.submit(&mut transport).unwrap();
        let id = controller.handoff().unwrap();
        assert!(Run::open(&id).is_err());
        let owner = Run::try_service(&id, &attempt, &spec).unwrap().unwrap();
        assert!(Run::try_service(&id, &attempt, &spec).unwrap().is_none());
        assert!(owner.retained_material(&attempt).unwrap().is_none());
        assert_eq!(transport.calls, ["submit-native"]);
    } else if operation == "early" {
        let pending = PendingCapture {
            invocation: invocation(),
            cwd: receipt.join("absent-source"),
            bootstrap: None,
            environment: None,
        };
        assert!(!pending.cwd.exists());
        let mut controller = admit(pending, binding()).unwrap();
        let attempt = controller
            .run
            .manifest()
            .children
            .keys()
            .next()
            .unwrap()
            .clone();
        assert!(
            controller
                .run
                .retained_material(&attempt)
                .unwrap()
                .is_none()
        );
        controller.submit(&mut transport).unwrap();
        assert_eq!(transport.calls, ["submit-native"]);
        // An authenticated acceptance is not ownership/InputReady permission.
        assert!(controller.claim_capture(&attempt, &mut transport).is_err());
        assert_eq!(transport.calls, ["submit-native", "status"]);
        let child = &controller.run.manifest().children[&attempt];
        let mut changed = child.pending_capture().unwrap().clone();
        changed.invocation.options.verbose = !changed.invocation.options.verbose;
        let crate::fleet::build_backend::agent::run::intent::Intent::Native(request) =
            &child.request
        else {
            panic!("native parent missing");
        };
        assert!(changed.validate(request).is_err()); // Private options bind too, not just the projection.
        std::fs::write(receipt.join("early-run-id"), controller.run_id()).unwrap();
    } else if operation == "early-reopen" {
        let id = std::fs::read_to_string(receipt.join("early-run-id")).unwrap();
        let mut controller = Controller::open(&id).unwrap();
        assert!(controller.submit(&mut transport).is_err());
        controller.poll(&mut transport).unwrap();
        assert_eq!(transport.calls, ["status"]);
    } else if operation == "record" {
        let mut controller = submission().record().unwrap();
        let child = controller.run.manifest().children.values().next().unwrap();
        assert_eq!(child.native.as_ref().unwrap().caller, invocation());
        assert_eq!(
            child.request.build().unwrap().selection,
            selection(&invocation())
        );
        assert_eq!(child.request.build().unwrap().required_hosts, ["app"]);
        controller.submit(&mut transport).unwrap();
        assert_eq!(transport.calls, ["submit"]);
        assert!(controller.submit(&mut transport).is_err());
        std::fs::write(receipt.join("run-id"), controller.run_id()).unwrap();
    } else {
        let id = std::fs::read_to_string(receipt.join("run-id")).unwrap();
        let mut controller = Controller::open(&id).unwrap();
        let attempt = controller
            .run
            .manifest()
            .children
            .keys()
            .next()
            .unwrap()
            .clone();
        let bytes = controller.run.retained_material(&attempt).unwrap().unwrap();
        let child = &controller.run.manifest().children[&attempt];
        Material::decode(&bytes, child.request.build().unwrap()).unwrap();
        assert!(controller.submit(&mut transport).is_err());
        assert!(transport.calls.is_empty());
        controller.poll(&mut transport).unwrap();
        assert_eq!(transport.calls, ["status"]);
        if operation == "replacement" {
            use std::os::unix::fs::PermissionsExt;
            let name = controller.run.path().join(format!("inputs-{attempt}.json"));
            let replacement = controller.run.path().join("foreign-input");
            std::fs::write(&replacement, &bytes).unwrap();
            std::fs::set_permissions(&replacement, std::fs::Permissions::from_mode(0o600)).unwrap();
            std::fs::rename(replacement, name).unwrap();
            assert!(controller.run.retained_material(&attempt).is_err());
        }
    }
}

// Synthetic protocol/disk records only: no acquisition, signatures, native
// retention, settlement or deployment are performed by this fixture.
fn consumer_fixture(
    transport: &mut MetadataTransport,
    expired: bool,
    planning: bool,
) -> (Controller, String) {
    use abird_host_agent::build_executor::{
        ArtifactDelivery, ArtifactReceipt, Outcome, Ownership, Phase, PoolHealth,
        preparation::{self, Disposition, PreparedInputs, PreparedTarget, ResolvedTarget},
        request::BuildTarget,
    };
    let mut controller = submission().record().unwrap();
    controller.submit(transport).unwrap();
    let attempt = controller
        .run
        .manifest()
        .children
        .keys()
        .next()
        .unwrap()
        .clone();
    let request = controller.run.manifest().children[&attempt]
        .request
        .build()
        .unwrap();
    let reserved_at = if expired { 1 } else { request.id.issued_at };
    let output = format!("/nix/store/{}-app", "a".repeat(32));
    let derivation = format!("/nix/store/{}-app.drv", "b".repeat(32));
    let mut prepared = PreparedInputs {
        version: preparation::VERSION,
        attempt_id: attempt.clone(),
        spec_digest: request.digest().unwrap(),
        source_path: format!("/nix/store/{}-source", "c".repeat(32)),
        tree_digest: "d".repeat(64),
        evaluation_digest: request.evaluation.digest().unwrap(),
        context_sources: BTreeMap::new(),
        caller_repository: None,
        resolved: vec![ResolvedTarget {
            host: "app".into(),
            configuration: "app".into(),
            disposition: Disposition::Build,
        }],
        targets: vec![PreparedTarget {
            target: BuildTarget {
                host: "app".into(),
                configuration: "app".into(),
                outputs: vec!["out".into()],
            },
            derivation: derivation.clone(),
        }],
        required_hosts: vec!["app".into()],
        selection_digest: "e".repeat(64),
        planning_digest: None,
        protection_digest: "f".repeat(64),
    };
    if planning {
        use crate::fleet::preparation::bound::{BoundPreparation, InputWitnesses, RetainedTrees};
        let inventory: crate::fleet::inventory::Inventory =
            serde_json::from_value(serde_json::json!({
                "hosts": {
                "app": {"groups": ["prod"], "knownHosts": "# fixture\n".repeat(1000)},
                "omitted": {"groups": ["prod"]}
            }
            }))
            .unwrap();
        let bound = BoundPreparation::new(
            request.clone(),
            RetainedTrees {
                source: prepared.source_path.clone(),
                snapshots: prepared.context_sources.clone(),
            },
        )
        .unwrap();
        let selection =
            crate::fleet::preparation::select_inventory(&inventory, bound.options()).unwrap();
        let probe = serde_json::json!(["app"]);
        let catalog =
            crate::fleet::preparation::PlanCatalog::from_probe(true, &probe.to_string()).unwrap();
        prepared = bound
            .candidate(
                &inventory,
                &catalog,
                &BTreeMap::from([(
                    "app".into(),
                    crate::fleet::build::NixStorePath::derivation(&derivation).unwrap(),
                )]),
                InputWitnesses {
                    tree_digest: prepared.tree_digest.clone(),
                    protection_digest: prepared.protection_digest.clone(),
                    caller_repository: None,
                },
            )
            .unwrap();
        let retained = abird_host_agent::build_executor::preparation::worker::Planning {
            version: 1,
            request: request.clone(),
            inventory: serde_json::to_value(&inventory).unwrap(),
            catalog: probe,
            selection: serde_json::to_string(&selection).unwrap(),
            activation: Default::default(),
            layers: serde_json::Value::Null,
        };
        prepared.planning_digest = Some(retained.digest().unwrap());
        retained.validate(&prepared).unwrap();
        transport.planning = Some(serde_json::to_vec(&retained).unwrap());
    }
    prepared.validate(request).unwrap();
    let artifacts = ArtifactReceipt {
        spec_digest: request.digest().unwrap(),
        preparation_digest: prepared.digest().unwrap(),
        closure_digest: "1".repeat(64),
        roots_digest: "2".repeat(64),
    };
    let ownership = Ownership {
        executor_version: 1,
        attempt_id: attempt.clone(),
        builder_id: "ci".into(),
        store_id: "store".into(),
        boot_id: "boot".into(),
        pool_epoch: std::num::NonZeroU64::new(1).unwrap(),
    };
    let delivery: ArtifactDelivery = serde_json::from_value(serde_json::json!({
        "version": 1, "ownership": ownership, "artifacts": artifacts, "prepared": prepared,
        "built": [{"drvPath": derivation, "outputs": {"out": output}}],
        "paths": {output: {"version": 1, "storeDir": "/nix/store", "narHash": format!("sha256-{}=", "A".repeat(43)),
            "narSize": 1, "references": [], "signatures": (0..50).map(|i| format!("{i}:{}", "s".repeat(200))).collect::<Vec<_>>(),
            "ca": null, "ultimate": false }}
    })).unwrap();
    let bytes = delivery.encode().unwrap();
    ArtifactDelivery::decode(&bytes, &ownership, &artifacts).unwrap();
    assert!(bytes.len() > 8192);
    transport.artifact = Some(bytes);
    controller
        .run
        .observe(
            &attempt,
            Response {
                version: protocol::VERSION,
                reply: Reply::Status {
                    snapshot: Box::new(protocol::Snapshot::Live {
                        pool: PoolHealth::Available,
                        acceptance: Acceptance {
                            attempt_id: attempt.clone(),
                            spec_digest: artifacts.spec_digest.clone(),
                            sequence: 1,
                        },
                        phase: Phase::Succeeded,
                        prepared_digest: Some(artifacts.preparation_digest.clone()),
                        input: None,
                        ownership: Some(ownership),
                        outcome: Some(Outcome::Succeeded { artifacts }),
                        accepted_at: reserved_at,
                        renewed_at: reserved_at,
                        reserved_at: Some(reserved_at),
                        settled_at: Some(reserved_at),
                    }),
                },
            },
        )
        .unwrap();
    (controller, attempt)
}

// Exercise the real claim/reopen and shared-store root-error boundaries. The
// final receipt is synthetic, as in consumer_fixture; no native trust claim.
fn acquisition_process(operation: &str, receipt: &Path, transport: &mut MetadataTransport) {
    use super::super::acquisition;
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};

    if operation == "consumer-acquisition-preflight" {
        for pending in [false, true] {
            let (mut controller, attempt) = consumer_fixture(transport, false, false);
            controller.artifact(&attempt, transport).unwrap();
            if pending {
                controller
                    .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
                    .unwrap();
                controller.begin_import(&attempt).unwrap();
            }
            let before = serde_json::to_vec(controller.run.manifest()).unwrap();
            let calls = transport.calls.clone();
            // This test executable is not an installed native consumer. Failure
            // must precede any claim, including recovery of an older uncertainty.
            assert!(
                acquisition::acquire(
                    &mut controller,
                    &attempt,
                    Path::new("/nix/store/unavailable/bin/nix"),
                    "https://cache.example",
                    false,
                )
                .is_err()
            );
            assert_eq!(
                serde_json::to_vec(controller.run.manifest()).unwrap(),
                before
            );
            assert_eq!(transport.calls, calls);
            assert_eq!(
                serde_json::to_vec(&Run::inspect(controller.run_id()).unwrap()).unwrap(),
                before
            );
        }
        return;
    }
    if operation == "consumer-acquisition-retire-ack" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        let delivery = controller.retained(&attempt).unwrap();
        let ack = abird_host_agent::build_executor::ConsumerAck {
            version: 1,
            ownership: delivery.ownership,
            artifacts: delivery.artifacts,
            consumer: controller.consumer(&attempt).unwrap().clone(),
            store_id: acquisition::native::STORE_ID.into(),
            acquisition_digest: "4".repeat(64),
            retention_digest: "5".repeat(64),
        };
        controller
            .record_consumption(&attempt, ack.clone())
            .unwrap();
        let id = controller.run_id().to_owned();
        assert!(Run::request_cancel(&id).unwrap().1);
        assert!(controller.abandon_consumer(&attempt, transport).is_err());
        // Even after cancellation, an already-issued exact ACK may be resent,
        // but never without a successful original-protection recheck.
        assert!(
            controller
                .send_recorded_ack(
                    &attempt,
                    transport,
                    |_| anyhow::bail!("roots unavailable"),
                    true
                )
                .is_err()
        );
        controller
            .send_recorded_ack(
                &attempt,
                transport,
                |receipt| {
                    assert_eq!(receipt, &ack);
                    Ok(())
                },
                true,
            )
            .unwrap();
        transport.consumer_state = Some(protocol::ConsumerState {
            receipt_digest: ack.digest().unwrap(),
            release_digest: Some("8".repeat(64)),
            retired: true,
        });
        controller
            .retire_observed(
                transport,
                std::time::Instant::now() + std::time::Duration::from_secs(1),
            )
            .unwrap();
        assert!(!transport.calls.contains(&"abandon"));
        assert!(Run::inspect(&id).is_err());
        return;
    }
    if operation == "consumer-acquisition-abandonment" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        assert!(controller.abandon_consumer(&attempt, transport).is_err());
        let id = controller.run_id().to_owned();
        assert!(Run::request_cancel(&id).unwrap().1);
        transport.lose_ack = true;
        assert!(controller.abandon_consumer(&attempt, transport).is_err());
        let original = controller.run.abandonment(&attempt).unwrap();
        assert!(controller.run.consumer_ack(&attempt).is_err());
        drop(controller);
        // A possibly accepted request cannot discard local recovery state.
        assert!(Controller::open(&id).unwrap().retire().is_err());
        let mut controller = Controller::open(&id).unwrap();
        controller.abandon_consumer(&attempt, transport).unwrap();
        assert_eq!(controller.run.abandonment(&attempt).unwrap(), original);
        controller.abandonment_status(&attempt, transport).unwrap();
        assert!(controller.abandonment_release(&attempt).unwrap().is_none());
        transport
            .abandonment_state
            .as_mut()
            .unwrap()
            .abandonment_digest = "9".repeat(64);
        assert!(controller.abandonment_status(&attempt, transport).is_err());
        let state = transport.abandonment_state.as_mut().unwrap();
        state.abandonment_digest = original.digest().unwrap();
        state.release_digest = Some("8".repeat(64));
        controller.abandonment_status(&attempt, transport).unwrap();
        transport.abandonment_state.as_mut().unwrap().release_digest = None;
        assert!(controller.abandonment_status(&attempt, transport).is_err());
        assert_eq!(
            controller.abandonment_release(&attempt).unwrap(),
            Some("8".repeat(64).as_str())
        );
        assert!(controller.run.consumer_ack(&attempt).is_err());
        assert!(controller.retire().is_err()); // Release alone is not completed cleanup.
        transport.abandonment_state.as_mut().unwrap().release_digest = Some("8".repeat(64));
        let controller = Controller::open(&id).unwrap();
        assert!(
            controller
                .retire_observed(
                    transport,
                    std::time::Instant::now() + std::time::Duration::from_millis(20)
                )
                .is_err()
        );
        assert!(Run::inspect(&id).is_ok());
        transport.reject_abandonment_status = true;
        let controller = Controller::open(&id).unwrap();
        assert!(
            controller
                .retire_observed(
                    transport,
                    std::time::Instant::now() + std::time::Duration::from_secs(1)
                )
                .is_err()
        );
        assert!(Run::inspect(&id).is_ok()); // NotFound is not cleanup evidence.
        transport.reject_abandonment_status = false;
        transport.finish_abandonment = true;
        let controller = Controller::open(&id).unwrap();
        controller
            .retire_observed(
                transport,
                std::time::Instant::now() + std::time::Duration::from_secs(1),
            )
            .unwrap();
        assert!(Run::inspect(&id).is_err());
        return;
    }
    if operation == "consumer-acquisition-import-retry" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        assert!(!controller.begin_import(&attempt).unwrap());
        assert!(controller.begin_import(&attempt).is_err());
        assert!(controller.require_import_reconciliation(&attempt).is_err());
        let id = controller.run_id().to_owned();
        drop(controller);
        let mut controller = Controller::open(&id).unwrap();
        controller.require_import_reconciliation(&attempt).unwrap();
        assert!(controller.begin_import(&attempt).unwrap());
        assert!(controller.require_import_reconciliation(&attempt).is_err());
        controller.native_helper_returned(&attempt).unwrap();
        assert!(controller.import_pending(&attempt).unwrap()); // Exit alone is insufficient.
        // Synthetic ABI 2 full local verification / immutable-effect proof.
        controller.import_effects_reconciled(&attempt).unwrap();
        assert!(!controller.import_pending(&attempt).unwrap());
        let delivery = controller.retained(&attempt).unwrap();
        let ack = abird_host_agent::build_executor::ConsumerAck {
            version: 1,
            ownership: delivery.ownership,
            artifacts: delivery.artifacts,
            consumer: controller.consumer(&attempt).unwrap().clone(),
            store_id: acquisition::native::STORE_ID.into(),
            acquisition_digest: "4".repeat(64),
            retention_digest: "5".repeat(64),
        };
        controller
            .record_consumption(&attempt, ack.clone())
            .unwrap();
        drop(controller);
        let controller = Controller::open(&id).unwrap();
        assert_eq!(controller.run.consumer_ack(&attempt).unwrap(), &ack);
        assert!(!controller.import_pending(&attempt).unwrap());
        assert!(Run::request_cancel(&id).unwrap().1);
        transport.consumer_state = Some(protocol::ConsumerState {
            receipt_digest: ack.digest().unwrap(),
            release_digest: Some("8".repeat(64)),
            retired: true,
        });
        controller
            .retire_observed(
                transport,
                std::time::Instant::now() + std::time::Duration::from_secs(1),
            )
            .unwrap();
        assert!(Run::inspect(&id).is_err());
        assert!(!transport.calls.contains(&"abandon"));
        return;
    }
    if operation == "consumer-acquisition-helper-fence" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::STORE_ID)
            .unwrap();
        let id = controller.run_id().to_owned();
        let helper_lock = controller.acquisition_lock().unwrap();
        controller.begin_native_helper(&attempt).unwrap();
        assert!(!controller.import_pending(&attempt).unwrap()); // Shared root writer, no import.
        Run::request_cancel(&id).unwrap();
        let calls = transport.calls.clone();
        assert!(
            controller
                .retire_observed(
                    transport,
                    std::time::Instant::now() + std::time::Duration::from_secs(1)
                )
                .is_err()
        );
        assert_eq!(transport.calls, calls); // No source release before helper fence.
        assert!(Controller::open(&id).is_err());
        drop(helper_lock);
        let controller = Controller::open(&id).unwrap();
        transport.finish_abandonment = true;
        controller
            .retire_observed(
                transport,
                std::time::Instant::now() + std::time::Duration::from_secs(1),
            )
            .unwrap();
        assert!(Run::inspect(&id).is_err());
        return;
    }
    if operation == "consumer-acquisition-import-discard" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        let id = controller.run_id().to_owned();
        let original = serde_json::to_value(controller.run.manifest()).unwrap()["children"]
            [&attempt]["consumption"]["acquisition"]
            .clone();
        controller.begin_import(&attempt).unwrap();
        // Model the still-live helper's inherited open description. Dropping
        // its parent isn't a fresh exclusion and cannot authorize cleanup.
        let helper_lock = controller.acquisition_lock().unwrap();
        assert!(controller.prepare_import_reconciliation(&attempt).is_err());
        assert!(controller.import_settled(&attempt).is_err());
        drop(controller);
        assert!(Controller::open(&id).is_err());
        drop(helper_lock);
        let mut controller = Controller::open(&id).unwrap();
        assert!(!controller.prepare_import_reconciliation(&attempt).unwrap()); // Active, not revoked.
        Run::request_cancel(&id).unwrap();
        assert!(controller.prepare_import_reconciliation(&attempt).unwrap());
        assert!(controller.import_pending(&attempt).unwrap());
        assert!(controller.abandon_consumer(&attempt, transport).is_err());
        assert!(controller.retire().is_err()); // No native effect witness yet.
        let mut controller = Controller::open(&id).unwrap();
        let state = serde_json::to_value(controller.run.manifest()).unwrap();
        let record = &state["children"][&attempt]["consumption"];
        assert_eq!(record["acquisition"], original);
        assert_eq!(record["abandoned"], true);
        assert_eq!(record["abandonment_requested"], true);
        assert!(controller.run.consumer_ack(&attempt).is_err());
        // Synthetic native discard-confinement witness, NOT process settlement
        // or consumption. Actual late-registration semantics need native/VM tests.
        controller.import_effects_reconciled(&attempt).unwrap();
        assert!(!controller.import_pending(&attempt).unwrap());
        assert!(controller.run.consumer_ack(&attempt).is_err());
        transport.finish_abandonment = true;
        controller
            .retire_observed(
                transport,
                std::time::Instant::now() + std::time::Duration::from_secs(1),
            )
            .unwrap();
        assert!(Run::inspect(&id).is_err());
        assert!(transport.calls.contains(&"abandon"));
        assert!(!transport.calls.contains(&"ack"));
        return;
    }
    if operation == "consumer-acquisition-import-crash" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        assert!(!controller.begin_import(&attempt).unwrap());
        assert!(controller.import_pending(&attempt).unwrap());
        std::fs::write(receipt.join("import-run-id"), controller.run_id()).unwrap();
        std::process::exit(0);
    }
    if operation == "consumer-acquisition-import-reopen" {
        let id = std::fs::read_to_string(receipt.join("import-run-id")).unwrap();
        let mut controller = Controller::open(&id).unwrap();
        let attempt = controller
            .run
            .manifest()
            .children
            .keys()
            .next()
            .unwrap()
            .clone();
        assert!(controller.import_pending(&attempt).unwrap());
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), acquisition::native::STORE_ID)
            .unwrap();
        assert!(controller.begin_import(&attempt).unwrap()); // Exact retry retains prior uncertainty.
        let delivery = controller.retained(&attempt).unwrap();
        let ack = abird_host_agent::build_executor::ConsumerAck {
            version: 1,
            ownership: delivery.ownership,
            artifacts: delivery.artifacts,
            consumer: controller.consumer(&attempt).unwrap().clone(),
            store_id: acquisition::native::STORE_ID.into(),
            acquisition_digest: "4".repeat(64),
            retention_digest: "5".repeat(64),
        };
        assert!(controller.record_consumption(&attempt, ack).is_err());
        assert!(Run::request_cancel(&id).unwrap().1);
        assert!(controller.abandon_consumer(&attempt, transport).is_err());
        assert!(controller.retire().is_err()); // Caller exit/cancellation cannot settle an importer.
        let mut controller = Controller::open(&id).unwrap();
        assert!(controller.import_pending(&attempt).unwrap());
        // Synthetic ABI 2 immutable-effect proof, not an inference from exit,
        // cancellation or synchronous completion of the newest retry alone.
        controller.import_effects_reconciled(&attempt).unwrap();
        assert!(!controller.import_pending(&attempt).unwrap());
        assert!(controller.run.consumer_ack(&attempt).is_err());
        controller.retire().unwrap();
        assert!(Run::inspect(&id).is_err());
        assert!(transport.calls.is_empty());
        return;
    }
    let source = "https://cache.example";
    let nix = Path::new("/nix/store/fixture-nix/bin/nix");
    let id_path = receipt.join("acquisition-run-id");
    let claim_path = receipt.join("acquisition-claim");
    let claim = |id: &str, attempt: &str| {
        serde_json::to_value(Run::inspect(id).unwrap()).unwrap()["children"][attempt]["consumption"]
            ["acquisition"]
            .clone()
    };
    if operation == "consumer-acquisition-crash" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        controller.artifact(&attempt, transport).unwrap();
        let roots = controller.consumer_roots(&attempt).unwrap();
        let binding = acquisition::binding_digest(source, nix, &roots, false).unwrap();
        controller
            .claim_acquisition(&attempt, &binding, acquisition::STORE_ID)
            .unwrap();
        assert!(controller.run.consumer_ack(&attempt).is_err());
        std::fs::write(&id_path, controller.run_id()).unwrap();
        std::fs::write(
            &claim_path,
            serde_json::to_vec(&claim(controller.run_id(), &attempt)).unwrap(),
        )
        .unwrap();
        // Abrupt exit: the claim is durable, but no acquisition effect ran.
        std::process::exit(0);
    }
    if operation == "consumer-acquisition-expired" {
        let (mut controller, attempt) = consumer_fixture(transport, true, false);
        controller.artifact(&attempt, transport).unwrap();
        let roots = controller.consumer_roots(&attempt).unwrap();
        let binding = acquisition::binding_digest(source, nix, &roots, false).unwrap();
        let runtime = controller.run.manifest().children[&attempt]
            .request
            .runtime_seconds();
        let path = controller.run.path().join("manifest.json");
        let id = controller.run_id().to_owned();
        drop(controller);
        // An originally valid claim whose original reservation has now expired.
        let mut envelope: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        envelope["manifest"]["children"][&attempt]["consumption"]["acquisition"] = serde_json::json!({
            "binding_digest": binding, "store_id": acquisition::STORE_ID,
            "claimed_at": 1, "deadline": 1 + runtime,
        });
        let manifest: super::super::run::Manifest =
            serde_json::from_value(envelope["manifest"].clone()).unwrap();
        envelope["checksum"] = serde_json::json!(abird_host_agent::sha256::digest_bytes(
            &serde_json::to_vec(&manifest).unwrap()
        ));
        std::fs::write(&path, serde_json::to_vec(&envelope).unwrap()).unwrap();
        let original = claim(&id, &attempt);
        let mut controller = Controller::open(&id).unwrap();
        assert!(
            controller
                .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
                .is_err()
        );
        assert_eq!(claim(&id, &attempt), original);
        assert!(controller.run.consumer_ack(&attempt).is_err());
        assert!(!roots.exists());
        let calls = transport.calls.len();
        controller.retire().unwrap(); // Expiry permits explicit local abandonment, not an ACK.
        assert!(Run::inspect(&id).is_err());
        assert_eq!(transport.calls.len(), calls);
        return;
    }
    if operation == "consumer-acquisition-cancelled" {
        let (mut controller, attempt) = consumer_fixture(transport, false, false);
        let delivery = controller.artifact(&attempt, transport).unwrap();
        let roots = controller.consumer_roots(&attempt).unwrap();
        let binding = acquisition::binding_digest(source, nix, &roots, false).unwrap();
        controller
            .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
            .unwrap();
        let id = controller.run_id().to_owned();
        let original = claim(&id, &attempt);
        assert!(!controller.cancelled().unwrap());
        assert!(Run::request_cancel(&id).unwrap().1);
        assert!(controller.cancelled().unwrap());
        drop(controller);
        let mut controller = Controller::open(&id).unwrap();
        assert!(acquisition::acquire(&mut controller, &attempt, nix, source, false).is_err());
        assert_eq!(claim(&id, &attempt), original);
        assert!(controller.run.consumer_ack(&attempt).is_err());
        assert!(!roots.exists());
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&roots)
            .unwrap();
        std::os::unix::fs::symlink(&delivery.outputs()[0], roots.join("0")).unwrap();
        std::fs::write(roots.join("foreign"), b"do not remove").unwrap();
        let calls = transport.calls.len();
        assert!(controller.retire().is_err()); // Abandonment persisted, cleanup vetoed.
        let state = serde_json::to_value(Run::inspect(&id).unwrap()).unwrap();
        assert_eq!(
            state["children"][&attempt]["consumption"]["abandoned"],
            true
        );
        assert!(state["children"][&attempt]["consumption"]["acknowledgement"].is_null());
        assert!(roots.join("0").is_symlink());
        assert_eq!(
            std::fs::read(roots.join("foreign")).unwrap(),
            b"do not remove"
        );
        let mut controller = Controller::open(&id).unwrap();
        assert!(
            controller
                .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
                .is_err()
        );
        let ack = abird_host_agent::build_executor::ConsumerAck {
            version: 1,
            ownership: delivery.ownership,
            artifacts: delivery.artifacts,
            consumer: controller.consumer(&attempt).unwrap().clone(),
            store_id: acquisition::STORE_ID.into(),
            acquisition_digest: "4".repeat(64),
            retention_digest: "5".repeat(64),
        };
        assert!(controller.record_consumption(&attempt, ack).is_err());
        drop(controller);
        // Simulate interruption after removing one exact link. Reopening may
        // finish abandonment but can never resume acquisition or fabricate ACK.
        std::fs::remove_file(roots.join("foreign")).unwrap();
        std::fs::remove_file(roots.join("0")).unwrap();
        Controller::open(&id).unwrap().retire().unwrap();
        assert!(!roots.parent().unwrap().exists());
        assert!(Run::inspect(&id).is_err());
        assert_eq!(transport.calls.len(), calls);
        return;
    }
    let id = std::fs::read_to_string(&id_path).unwrap();
    let mut controller = Controller::open(&id).unwrap();
    let attempt = controller
        .run
        .manifest()
        .children
        .keys()
        .next()
        .unwrap()
        .clone();
    let roots = controller.consumer_roots(&attempt).unwrap();
    let binding = acquisition::binding_digest(source, nix, &roots, false).unwrap();
    let original: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&claim_path).unwrap()).unwrap();
    assert!(Controller::open(&id).is_err()); // Original run exclusion, no second writer.
    assert!(Run::caller_active(&id).unwrap());
    assert!(Run::caller_active("../foreign").is_err());
    if operation == "consumer-acquisition-recorded" {
        let ack = controller.run.consumer_ack(&attempt).unwrap().clone();
        assert!(
            controller
                .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
                .is_err()
        );
        controller
            .require_acquisition_binding(&attempt, &binding, acquisition::STORE_ID)
            .unwrap();
        assert!(
            controller
                .require_acquisition_binding(&attempt, &"0".repeat(64), acquisition::STORE_ID)
                .is_err()
        );
        assert!(
            controller
                .require_acquisition_binding(&attempt, &binding, "other-store")
                .is_err()
        );
        assert_eq!(controller.run.consumer_ack(&attempt).unwrap(), &ack);
        assert_eq!(claim(&id, &attempt), original);
        assert!(Run::request_cancel(&id).unwrap().1);
        assert!(controller.retire().is_err()); // An issued ACK cannot be abandoned, even if cancelled.
        let controller = Controller::open(&id).unwrap();
        assert_eq!(controller.run.consumer_ack(&attempt).unwrap(), &ack);
        assert!(transport.calls.is_empty());
        return;
    }
    for changed in [
        acquisition::binding_digest("https://other.example", nix, &roots, false).unwrap(),
        acquisition::binding_digest(source, Path::new("/other/bin/nix"), &roots, false).unwrap(),
        acquisition::binding_digest(source, nix, &roots.with_file_name("other"), false).unwrap(),
        acquisition::binding_digest(source, nix, &roots, true).unwrap(),
    ] {
        assert!(
            controller
                .reconcile_acquisition(&attempt, &changed, acquisition::STORE_ID)
                .is_err()
        );
    }
    assert!(
        controller
            .reconcile_acquisition(&attempt, &binding, "other-store")
            .is_err()
    );
    assert!(
        controller
            .reconcile_acquisition(&"0".repeat(64), &binding, acquisition::STORE_ID)
            .is_err()
    );
    assert!(!roots.exists()); // Mismatch rejection precedes all root effects.
    assert!(controller.retire().is_err()); // Active unacknowledged claims cannot be abandoned.
    assert!(!Run::caller_active(&id).unwrap()); // Inactive is not settlement/retirement proof.
    let mut controller = Controller::open(&id).unwrap();
    let (delivery, first_cutoff) = controller
        .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
        .unwrap();
    let (_, second_cutoff) = controller
        .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
        .unwrap();
    assert!(second_cutoff <= first_cutoff + std::time::Duration::from_millis(10));
    assert_eq!(claim(&id, &attempt), original);
    assert!(
        controller
            .claim_acquisition(&attempt, &binding, acquisition::STORE_ID)
            .is_err()
    ); // Same-binding retries do not allocate another claim.
    // Missing consumer preflight leaves the original claim intact. Explicitly
    // model a prior helper's partial roots; this is not native acquisition.
    assert!(std::fs::symlink_metadata(&delivery.outputs()[0]).is_err());
    let base = roots.parent().unwrap().parent().unwrap();
    std::fs::DirBuilder::new().mode(0o700).create(base).unwrap();
    assert!(acquisition::acquire(&mut controller, &attempt, nix, source, false).is_err());
    assert!(!roots.exists());
    for directory in [roots.parent().unwrap(), roots.as_path()] {
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(directory)
            .unwrap();
    }
    std::os::unix::fs::symlink(&delivery.outputs()[0], roots.join("0")).unwrap();
    let inode = std::fs::symlink_metadata(roots.join("0")).unwrap().ino();
    drop(controller);
    let mut controller = Controller::open(&id).unwrap();
    controller.begin_native_helper(&attempt).unwrap(); // Synthetic prior helper uncertainty.
    assert!(acquisition::acquire(&mut controller, &attempt, nix, source, false).is_err());
    assert_eq!(
        std::fs::symlink_metadata(roots.join("0")).unwrap().ino(),
        inode
    );
    assert_eq!(claim(&id, &attempt), original);
    assert!(controller.run.consumer_ack(&attempt).is_err());
    controller
        .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
        .unwrap();
    let ack = abird_host_agent::build_executor::ConsumerAck {
        version: 1,
        ownership: delivery.ownership,
        artifacts: delivery.artifacts,
        consumer: controller.consumer(&attempt).unwrap().clone(),
        store_id: acquisition::STORE_ID.into(),
        acquisition_digest: "4".repeat(64),
        retention_digest: "5".repeat(64),
    };
    // Failed native acquisition supplied no bound receipt/reaping witness.
    // Even this synthetic state transition must not bypass the helper fence.
    assert!(
        controller
            .record_consumption(&attempt, ack.clone())
            .is_err()
    );
    drop(controller);
    let mut controller = Controller::open(&id).unwrap();
    controller
        .reconcile_acquisition(&attempt, &binding, acquisition::STORE_ID)
        .unwrap();
    // Synthetic ACK after fresh exclusion, not native acquisition evidence.
    controller.record_consumption(&attempt, ack).unwrap();
    assert_eq!(claim(&id, &attempt), original);
    assert!(transport.calls.is_empty()); // No submit, source delivery, import or ACK dispatch.
}

fn consumer_process(operation: &str, receipt: &Path, transport: &mut MetadataTransport) {
    use abird_host_agent::build_executor::ConsumerAck;
    use std::os::unix::fs::PermissionsExt;
    if operation.starts_with("consumer-acquisition") {
        acquisition_process(operation, receipt, transport);
        return;
    }
    if operation.starts_with("consumer-planning") {
        planning_process(operation, receipt, transport);
        return;
    }
    if matches!(
        operation,
        "consumer" | "consumer-uncertain" | "consumer-expired" | "consumer-cancel"
    ) {
        let (mut controller, attempt) =
            consumer_fixture(transport, operation == "consumer-expired", false);
        let id = controller.run_id().to_owned();
        if operation == "consumer-uncertain" {
            let path = controller
                .run
                .path()
                .join(format!("artifacts-{attempt}.json"));
            std::fs::write(&path, b"unbound residue").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            assert!(controller.artifact(&attempt, transport).is_err());
            let calls = transport.calls.len();
            drop(controller);
            let mut reopened = Controller::open(&id).unwrap();
            assert!(reopened.artifact(&attempt, transport).is_err());
            assert!(
                reopened
                    .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                    .is_err()
            );
            assert_eq!(transport.calls.len(), calls); // No recreation or redelivery.
            return;
        }
        let delivery = controller.artifact(&attempt, transport).unwrap();
        if operation == "consumer-expired" {
            assert!(
                controller
                    .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                    .is_err()
            );
            drop(controller);
            let mut reopened = Controller::open(&id).unwrap();
            assert!(
                reopened
                    .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                    .is_err()
            );
            assert!(serde_json::to_value(Run::inspect(&id).unwrap()).unwrap()["children"][&attempt]["consumption"]["acquisition"].is_null());
            return;
        }
        assert!(controller.run.consumer_ack(&attempt).is_err());
        controller
            .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
            .unwrap();
        assert!(
            controller
                .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                .is_err()
        );
        // The claim is not renewed, but exact idempotent import/reverification
        // can reconcile even for a future non-shared destination store.
        controller
            .reconcile_acquisition(&attempt, &"3".repeat(64), "consumer-store")
            .unwrap();
        let acknowledgement = ConsumerAck {
            version: 1,
            ownership: delivery.ownership,
            artifacts: delivery.artifacts,
            consumer: binding().controller,
            store_id: "consumer-store".into(),
            acquisition_digest: "4".repeat(64),
            retention_digest: "5".repeat(64),
        };
        controller
            .record_consumption(&attempt, acknowledgement.clone())
            .unwrap();
        controller
            .record_consumption(&attempt, acknowledgement.clone())
            .unwrap();
        let mut foreign = acknowledgement.clone();
        foreign.retention_digest = "6".repeat(64);
        assert!(controller.record_consumption(&attempt, foreign).is_err());
        assert!(controller.source_release(&attempt).unwrap().is_none());
        if operation == "consumer-cancel" {
            let calls = transport.calls.len();
            assert!(
                controller
                    .acknowledge_consumer(&attempt, transport, |_| {
                        ensure!(Run::request_cancel(&id)?.1, "test cancel was not durable");
                        Ok(())
                    })
                    .is_err()
            );
            assert_eq!(transport.calls.len(), calls);
            assert!(transport.acknowledged.is_none());
            return;
        }
        transport.lose_ack = true;
        assert!(
            controller
                .acknowledge_consumer(&attempt, transport, |_| Ok(()))
                .is_err()
        );
        assert_eq!(
            transport.acknowledged,
            Some(acknowledgement.digest().unwrap())
        );
        assert!(!serde_json::to_value(Run::inspect(&id).unwrap()).unwrap()["children"][&attempt]["consumption"]["confirmed"].as_bool().unwrap());
        std::fs::write(receipt.join("consumer-run-id"), id).unwrap();
        return;
    }
    let id = std::fs::read_to_string(receipt.join("consumer-run-id")).unwrap();
    let mut controller = Controller::open(&id).unwrap();
    let attempt = controller
        .run
        .manifest()
        .children
        .keys()
        .next()
        .unwrap()
        .clone();
    let original = controller.run.consumer_ack(&attempt).unwrap().clone();
    if operation == "consumer-retire" {
        // Completed handoff: consumer roots, then the record, are released.
        let roots = controller.consumer_roots(&attempt).unwrap();
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&roots)
            .unwrap();
        let delivery = controller.run.retained_artifact(&attempt).unwrap().unwrap();
        std::os::unix::fs::symlink(&delivery.outputs()[0], roots.join("0")).unwrap();
        let path = controller.run.path().to_owned();
        controller.retire().unwrap();
        assert!(!path.exists() && Run::inspect(&id).is_err());
        assert!(
            !path
                .parent()
                .unwrap()
                .join(format!(".retired-{id}"))
                .exists()
        );
        return;
    }
    if operation == "consumer-replaced" {
        let bytes = controller
            .run
            .retained_artifact(&attempt)
            .unwrap()
            .unwrap()
            .encode()
            .unwrap();
        let replacement = controller.run.path().join("replacement-artifact");
        std::fs::write(&replacement, bytes).unwrap();
        std::fs::set_permissions(&replacement, std::fs::Permissions::from_mode(0o600)).unwrap();
        let artifact = controller
            .run
            .path()
            .join(format!("artifacts-{attempt}.json"));
        let original = controller.run.path().join("original-artifact");
        std::fs::rename(&artifact, &original).unwrap();
        std::fs::rename(replacement, &artifact).unwrap();
        assert!(controller.artifact(&attempt, transport).is_err());
        assert!(
            controller
                .acknowledge_consumer(&attempt, transport, |_| Ok(()))
                .is_err()
        );
        assert!(transport.calls.is_empty());
        assert!(controller.retire().is_err()); // Cleanup also requires the original retained artifact.
        std::fs::remove_file(&artifact).unwrap();
        std::fs::rename(original, artifact).unwrap();
        return;
    }
    controller.artifact(&attempt, transport).unwrap(); // Retained inode, no source query.
    assert!(
        controller
            .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
            .is_err()
    );
    assert!(
        controller
            .claim_acquisition(&attempt, &"7".repeat(64), "replacement-store")
            .is_err()
    );
    assert!(
        controller
            .acknowledge_consumer(&attempt, transport, |_| anyhow::bail!(
                "retention unavailable"
            ))
            .is_err()
    );
    assert!(transport.calls.is_empty());
    controller.consumer_status(&attempt, transport).unwrap(); // Unknown ACK remains unknown.
    // Unpublished residue of a writer killed mid-save never blocks reconnect.
    std::fs::write(controller.run.path().join("manifest.next"), b"{").unwrap();
    controller
        .acknowledge_consumer(&attempt, transport, |receipt| {
            ensure!(receipt == &original, "consumer receipt differs");
            Ok(())
        })
        .unwrap();
    assert!(controller.consumer_status(&attempt, transport).is_err()); // Cannot forget confirmed ACK.
    let mut state = protocol::ConsumerState {
        receipt_digest: original.digest().unwrap(),
        release_digest: None,
        retired: false,
    };
    transport.consumer_state = Some(state.clone());
    controller.consumer_status(&attempt, transport).unwrap();
    assert!(controller.source_release(&attempt).unwrap().is_none());
    drop(controller);
    // Consumed but release unobserved: the caller record is never retired.
    assert!(Controller::open(&id).unwrap().retire().is_err());
    let mut controller = Controller::open(&id).unwrap();
    state.release_digest = Some("8".repeat(64));
    transport.consumer_state = Some(state.clone());
    controller.consumer_status(&attempt, transport).unwrap();
    assert_eq!(
        controller.source_release(&attempt).unwrap(),
        Some("8".repeat(64).as_str())
    );
    let wrong = "e".repeat(64);
    let request = Request {
        version: protocol::VERSION,
        command: protocol::Command::ConsumerStatus {
            attempt_id: wrong.clone(),
        },
    };
    let response = Response {
        version: protocol::VERSION,
        reply: Reply::ConsumerStatus {
            attempt_id: wrong,
            state: Some(state.clone()),
        },
    };
    assert!(
        controller
            .run
            .observe_consumer(&attempt, &request, &response)
            .is_err()
    );
    state.retired = true;
    transport.consumer_state = Some(state.clone());
    controller.consumer_status(&attempt, transport).unwrap();
    state.retired = false;
    transport.consumer_state = Some(state);
    assert!(controller.consumer_status(&attempt, transport).is_err());
    assert!(
        !transport
            .calls
            .iter()
            .any(|call| matches!(*call, "submit" | "artifact"))
    );
}

fn planning_process(operation: &str, receipt: &Path, transport: &mut MetadataTransport) {
    use std::os::unix::fs::PermissionsExt;
    if matches!(
        operation,
        "consumer-planning" | "consumer-planning-uncertain"
    ) {
        let (mut controller, attempt) = consumer_fixture(transport, false, true);
        let id = controller.run_id().to_owned();
        let delivery = controller.artifact(&attempt, transport).unwrap();
        assert!(
            controller
                .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                .is_err()
        );
        if operation == "consumer-planning-uncertain" {
            let path = controller
                .run
                .path()
                .join(format!("planning-{attempt}.json"));
            std::fs::write(&path, b"unbound residue").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            assert!(controller.planning(&attempt, transport).is_err());
            let calls = transport.calls.len();
            drop(controller);
            let mut reopened = Controller::open(&id).unwrap();
            assert!(reopened.planning(&attempt, transport).is_err());
            assert!(
                reopened
                    .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
                    .is_err()
            );
            assert_eq!(transport.calls.len(), calls);
            return;
        }
        let planning = controller.planning(&attempt, transport).unwrap().unwrap();
        assert_eq!(
            &planning.request,
            controller.run.manifest().children[&attempt]
                .request
                .build()
                .unwrap()
        );
        assert!(
            transport
                .calls
                .iter()
                .filter(|call| **call == "planning")
                .count()
                > 1
        );
        let calls = transport.calls.len();
        controller.planning(&attempt, transport).unwrap().unwrap();
        let crate::fleet::preparation::bound::Restored {
            inventory, catalog, ..
        } = controller.restored_planning(&attempt).unwrap();
        assert_eq!(serde_json::to_value(inventory).unwrap(), planning.inventory);
        assert!(matches!(
            catalog,
            crate::fleet::preparation::PlanCatalog::Native(_)
        ));
        assert_eq!(transport.calls.len(), calls);
        controller
            .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
            .unwrap();
        controller
            .record_consumption(
                &attempt,
                abird_host_agent::build_executor::ConsumerAck {
                    version: 1,
                    ownership: delivery.ownership,
                    artifacts: delivery.artifacts,
                    consumer: binding().controller,
                    store_id: "consumer-store".into(),
                    acquisition_digest: "4".repeat(64),
                    retention_digest: "5".repeat(64),
                },
            )
            .unwrap();
        std::fs::write(receipt.join("planning-run-id"), id).unwrap();
        return;
    }
    let id = std::fs::read_to_string(receipt.join("planning-run-id")).unwrap();
    let mut controller = Controller::open(&id).unwrap();
    let attempt = controller
        .run
        .manifest()
        .children
        .keys()
        .next()
        .unwrap()
        .clone();
    let planning = controller.planning(&attempt, transport).unwrap().unwrap();
    assert_eq!(
        serde_json::to_value(controller.restored_planning(&attempt).unwrap().inventory).unwrap(),
        planning.inventory
    );
    assert!(transport.calls.is_empty()); // No data download or source query after reopening.
    if operation == "consumer-planning-replaced" {
        let replacement = controller.run.path().join("replacement-planning");
        std::fs::write(&replacement, serde_json::to_vec(&planning).unwrap()).unwrap();
        std::fs::set_permissions(&replacement, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::rename(
            replacement,
            controller
                .run
                .path()
                .join(format!("planning-{attempt}.json")),
        )
        .unwrap();
        assert!(controller.planning(&attempt, transport).is_err());
        assert!(
            controller
                .acknowledge_consumer(&attempt, transport, |_| Ok(()))
                .is_err()
        );
        assert!(transport.calls.is_empty());
        return;
    }
    assert!(
        controller
            .claim_acquisition(&attempt, &"3".repeat(64), "consumer-store")
            .is_err()
    );
    controller
        .acknowledge_consumer(&attempt, transport, |_| Ok(()))
        .unwrap();
    assert_eq!(transport.calls, ["ack"]);
}

fn repository_process(operation: &str, receipt: &Path) {
    let path = receipt.join("repository-run");
    let mut controller = if operation == "repository-record" {
        let invocation = Invocation::parse_legacy([
            "build",
            "--strategy=agent",
            "--no-override",
            "--sha",
            &"a".repeat(40),
        ])
        .unwrap();
        let mut runtime = crate::fleet::runtime::RuntimeConfig::from_environment();
        runtime.git_program = "/no-git-before-admission".into();
        runtime.nix_program = "/no-nix-before-admission".into();
        let controller = admit_repository(
            invocation,
            "/no-source-read-before-admission".into(),
            binding(),
            &runtime,
        )
        .unwrap();
        std::fs::write(&path, controller.run_id()).unwrap();
        controller
    } else {
        Controller::open(&std::fs::read_to_string(path).unwrap()).unwrap()
    };
    let (attempt, child) = controller.run.manifest().children.iter().next().unwrap();
    let record = serde_json::to_value(child).unwrap();
    assert_eq!(record["capture_claimed"], false);
    assert_eq!(record["submit_claimed"], false);
    assert!(record["remote_capture"].is_null());
    let bytes = controller.run.retained_material(attempt).unwrap().unwrap();
    let super::super::run::intent::Intent::Native(request) = &child.request else {
        panic!("native recipe")
    };
    let abird_host_agent::build_executor::native_intent::Delivery::Repository { recipe } =
        abird_host_agent::build_executor::native_intent::Delivery::decode(&bytes, request).unwrap()
    else {
        panic!("no caller image")
    };
    configured_invocation(request, &recipe.source, false).unwrap();
    assert_eq!(recipe.source.revision, "a".repeat(40));
    assert_eq!(
        recipe.source_root,
        Path::new("/no-source-read-before-admission")
    );
    if operation == "repository-reopen" {
        let mut transport = MetadataTransport::new();
        assert!(controller.submit(&mut transport).is_err());
        assert!(transport.calls.is_empty());
    }
}

#[test]
fn ci_parent_reuses_native_forwarding_and_resolved_patch_without_recapture() {
    use crate::fleet::ci_runtime::{
        CiRepositorySource, CiRequestInput, owned_submission, prepare_ci_trigger,
    };
    use crate::fleet::environment::Environment;
    use crate::fleet::inventory::Inventory;
    use crate::fleet::repository::CiCleanMode;
    struct SourceFixture {
        resolutions: usize,
        captures: usize,
    }
    impl CiRepositorySource for SourceFixture {
        fn resolve_commit(&mut self, _root: &Path, _reference: &str) -> Result<CommitSha> {
            self.resolutions += 1;
            CommitSha::parse("a".repeat(40))
        }
        fn capture_staged_patch(&mut self, _root: &Path) -> Result<Option<StagedPatch>> {
            self.captures += 1;
            Ok(source().patch)
        }
    }
    let caller = Invocation::parse_legacy([
        "deploy",
        "--ci-trigger",
        "--strategy=agent",
        "--dirty-staged",
        "--route=ts",
    ])
    .unwrap();
    let mut inventory = Inventory::default();
    inventory.config.default_group = Some("prod infra".into());
    let mut repository = SourceFixture {
        resolutions: 0,
        captures: 0,
    };
    let prepared = prepare_ci_trigger(
        &CiRequestInput {
            action: "deploy",
            clean_mode: CiCleanMode::Auto,
            options: &caller.options,
            inventory: &inventory,
            repository_root: Path::new("/native/source"),
        },
        &mut repository,
    )
    .unwrap();
    let submission = owned_submission(
        &caller,
        prepared,
        &Environment::from_map(BTreeMap::new()),
        "/native/source".into(),
        locations(),
        binding(),
        BTreeMap::new(),
    )
    .unwrap();
    assert_eq!((repository.resolutions, repository.captures), (2, 1));
    assert_eq!(
        submission.record.effective.options.groups,
        ["prod", "infra"]
    );
    assert!(submission.record.effective.options.hosts.is_none());
    assert!(submission.record.effective.options.no_override);
    assert!(!submission.record.effective.options.ci_trigger);
    assert_eq!(
        submission.record.effective.options.sha.as_deref(),
        Some("a".repeat(40).as_str())
    );
    assert_eq!(
        submission.record.effective.options.route,
        crate::fleet::inventory_routing::RouteRequest::Auto
    );
    assert_eq!(
        submission.source.patch.unwrap().bytes,
        source().patch.unwrap().bytes
    );
}

#[test]
fn acquisition_source_uses_original_signed_cache_never_builder_ingress_or_inline_trust() {
    let mut options = invocation().options;
    assert!(acquisition_source(None, None).is_err());
    assert!(acquisition_source(Some(&options), None).is_err());
    options.build_cache_url = Some("http://abird-ci:5000".into());
    assert_eq!(
        acquisition_source(Some(&options), None).unwrap(),
        "http://abird-ci:5000"
    );
    for forced in [
        "http://abird-ci:5000?trusted=true",
        "ssh-ng://root@abird-ci",
    ] {
        options.build_cache_url = Some(forced.into());
        assert!(
            acquisition_source(Some(&options), None).is_err(),
            "{forced}"
        );
    }
}
