#![allow(dead_code)]

#[path = "../src/fleet/ci_runtime.rs"]
mod ci_runtime;
#[path = "../src/fleet/cli.rs"]
mod cli;
#[path = "../src/fleet/environment.rs"]
mod environment;
#[path = "../src/fleet/inventory.rs"]
mod inventory;
#[path = "../src/fleet/repository.rs"]
mod repository;
#[path = "../src/fleet/system.rs"]
mod system;

use std::collections::{BTreeMap, VecDeque};
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use tempfile::TempDir;

use ci_runtime::{
    AgeOrFileCredentialMaterializer, CiConnectionInput, CiCredentialMaterializer, CiPrivateKey,
    CiPrograms, CiRepositorySource, CiRequestInput, CiRevisionSource, ProcessCiRepositorySource,
    SystemCiExecutor, execute_ci_trigger, prepare_ci_trigger, resolve_ci_connection,
};
use cli::{LogFormat, Options};
use inventory::{DeployConfig, Host, HostDefaults, Inventory};
use repository::{
    CiCleanMode, CiHostSelection, CommandOutput, CommandRequest, CommandRunner, CommitSha,
    StagedPatch, decode_argv,
};

fn sha(value: &str) -> CommitSha {
    CommitSha::parse(value).unwrap()
}

fn inventory() -> Inventory {
    Inventory {
        hosts: BTreeMap::from([(
            "controller-node".to_owned(),
            Host {
                target: Some("ci.internal".to_owned()),
                user: Some("inventory-user".to_owned()),
                identity_key: Some(PathBuf::from("fixtures/inventory-key.enc")),
                known_hosts: Some("ci.internal ssh-ed25519 inventory-host-key".to_owned()),
                port: Some(2222),
                resource_id: Some("ci-role".to_owned()),
                ..Host::default()
            },
        )]),
        config: DeployConfig {
            controller: Some("ci-role".to_owned()),
            default_group: Some("prod".to_owned()),
            default_hosts: Some("all".to_owned()),
            host_defaults: HostDefaults::default(),
            ..DeployConfig::default()
        },
    }
}

#[derive(Default)]
struct FakeRepository {
    resolved: BTreeMap<String, CommitSha>,
    patch: Option<StagedPatch>,
    resolve_calls: Vec<String>,
    captures: usize,
}

impl CiRepositorySource for FakeRepository {
    fn resolve_commit(&mut self, _root: &Path, reference: &str) -> Result<CommitSha> {
        self.resolve_calls.push(reference.to_owned());
        self.resolved
            .get(reference)
            .cloned()
            .ok_or_else(|| anyhow!("missing synthetic revision {reference}"))
    }

    fn capture_staged_patch(&mut self, _root: &Path) -> Result<Option<StagedPatch>> {
        self.captures += 1;
        Ok(self.patch.clone())
    }
}

fn request_input<'a>(
    options: &'a Options,
    inventory: &'a Inventory,
    root: &'a Path,
) -> CiRequestInput<'a> {
    CiRequestInput {
        action: "deploy",
        clean_mode: CiCleanMode::Auto,
        options,
        inventory,
        repository_root: root,
    }
}

#[test]
fn default_head_and_group_only_scope_are_forwarded_without_host_flattening() {
    let fixture = TempDir::new().unwrap();
    let inventory = inventory();
    let options = Options::default();
    let mut repository = FakeRepository {
        resolved: BTreeMap::from([("HEAD".to_owned(), sha("abcdef0123456789"))]),
        ..FakeRepository::default()
    };

    let prepared = prepare_ci_trigger(
        &request_input(&options, &inventory, fixture.path()),
        &mut repository,
    )
    .unwrap();

    assert_eq!(prepared.revision_source, CiRevisionSource::Head);
    assert_eq!(repository.resolve_calls, ["HEAD"]);
    assert!(
        prepared
            .plan
            .argv
            .windows(2)
            .any(|pair| pair == ["--group", "prod"])
    );
    assert!(!prepared.plan.argv.iter().any(|arg| arg == "--host"));
    assert!(!prepared.plan.argv.iter().any(|arg| arg == "--hosts"));
}

#[test]
fn explicit_group_and_singular_or_plural_host_selection_remain_distinct() {
    let fixture = TempDir::new().unwrap();
    let inventory = inventory();
    let mut options = Options {
        sha: Some("abcdef0".to_owned()),
        groups: vec!["prod".to_owned(), "edge".to_owned()],
        host: Some("one".to_owned()),
        ..Options::default()
    };
    let mut repository = FakeRepository {
        resolved: BTreeMap::from([("abcdef0".to_owned(), sha("abcdef0123456789"))]),
        ..FakeRepository::default()
    };
    let singular = prepare_ci_trigger(
        &request_input(&options, &inventory, fixture.path()),
        &mut repository,
    )
    .unwrap();
    assert!(
        singular
            .plan
            .argv
            .windows(2)
            .any(|pair| pair == ["--group", "prod,edge"])
    );
    assert!(
        singular
            .plan
            .argv
            .windows(2)
            .any(|pair| pair == ["--host", "one"])
    );

    options.host = None;
    options.hosts = Some("app-*,-old".to_owned());
    let plural = prepare_ci_trigger(
        &request_input(&options, &inventory, fixture.path()),
        &mut repository,
    )
    .unwrap();
    assert!(
        plural
            .plan
            .argv
            .windows(2)
            .any(|pair| pair == ["--hosts", "app-*,-old"])
    );
}

#[test]
fn staged_patch_is_captured_proven_against_resolved_target_and_sent_as_exact_stdin() {
    let fixture = TempDir::new().unwrap();
    let inventory = inventory();
    let options = Options {
        sha: Some("abcdef0".to_owned()),
        groups: vec!["prod".to_owned()],
        dirty_staged: true,
        ..Options::default()
    };
    let full = sha("abcdef0123456789");
    let mut repository = FakeRepository {
        resolved: BTreeMap::from([
            ("abcdef0".to_owned(), full.clone()),
            (full.as_str().to_owned(), full.clone()),
        ]),
        patch: Some(StagedPatch {
            base: full,
            bytes: b"GIT binary patch\0synthetic".to_vec(),
        }),
        ..FakeRepository::default()
    };

    let prepared = prepare_ci_trigger(
        &request_input(&options, &inventory, fixture.path()),
        &mut repository,
    )
    .unwrap();

    assert_eq!(repository.captures, 1);
    assert_eq!(
        prepared.plan.stdin.as_deref(),
        Some(b"GIT binary patch\0synthetic".as_slice())
    );
    assert!(
        prepared
            .plan
            .argv
            .iter()
            .any(|arg| arg == "--dirty-staged-patch-stdin")
    );
    assert!(prepared.base_proven);
}

#[test]
fn absent_staged_changes_continue_from_committed_state_but_base_mismatch_fails() {
    let fixture = TempDir::new().unwrap();
    let inventory = inventory();
    let options = Options {
        groups: vec!["prod".to_owned()],
        dirty_staged: true,
        ..Options::default()
    };
    let mut empty = FakeRepository {
        resolved: BTreeMap::from([("HEAD".to_owned(), sha("abcdef0123456789"))]),
        ..FakeRepository::default()
    };
    let prepared = prepare_ci_trigger(
        &request_input(&options, &inventory, fixture.path()),
        &mut empty,
    )
    .unwrap();
    assert!(prepared.plan.stdin.is_none());
    assert!(!prepared.plan.argv.iter().any(|arg| arg == "--dirty-staged"));

    let target = sha("abcdef0123456789");
    let base = sha("1234567890abcdef");
    let mut mismatch = FakeRepository {
        resolved: BTreeMap::from([
            ("HEAD".to_owned(), target),
            (base.as_str().to_owned(), base.clone()),
        ]),
        patch: Some(StagedPatch {
            base,
            bytes: b"patch".to_vec(),
        }),
        ..FakeRepository::default()
    };
    assert!(
        prepare_ci_trigger(
            &request_input(&options, &inventory, fixture.path()),
            &mut mismatch,
        )
        .unwrap_err()
        .to_string()
        .contains("does not match")
    );
}

#[test]
fn ci_connection_uses_explicit_values_then_inventory_system_values_then_defaults() {
    let inventory = inventory();
    let explicit = Options {
        ci_host: Some("literal.example".to_owned()),
        ci_user: Some("runner".to_owned()),
        ci_ssh_key: Some("INLINE PRIVATE KEY".to_owned()),
        ci_known_hosts: Some("literal.example ssh-ed25519 explicit".to_owned()),
        ..Options::default()
    };
    let connection = resolve_ci_connection(&CiConnectionInput {
        inventory: &inventory,
        options: &explicit,
        default_private_key: Some(Path::new("fixtures/default-ci-key.enc")),
    })
    .unwrap();
    assert_eq!(connection.target, "literal.example");
    assert_eq!(connection.user, "runner");
    assert_eq!(
        connection.private_key,
        Some(CiPrivateKey::Inline("INLINE PRIVATE KEY".to_owned()))
    );
    assert_eq!(
        connection.known_hosts.as_deref(),
        Some("literal.example ssh-ed25519 explicit")
    );

    let inherited = resolve_ci_connection(&CiConnectionInput {
        inventory: &inventory,
        options: &Options::default(),
        default_private_key: Some(Path::new("fixtures/default-ci-key.enc")),
    })
    .unwrap();
    assert_eq!(inherited.inventory_name.as_deref(), Some("controller-node"));
    assert_eq!(inherited.target, "ci.internal");
    assert_eq!(inherited.port, 2222);
    assert_eq!(inherited.user, "inventory-user");
    assert_eq!(
        inherited.private_key,
        Some(CiPrivateKey::Source(PathBuf::from(
            "fixtures/default-ci-key.enc"
        )))
    );
    assert_eq!(
        inherited.known_hosts.as_deref(),
        Some("ci.internal ssh-ed25519 inventory-host-key")
    );
}

#[derive(Default)]
struct CopyMaterializer;

impl CiCredentialMaterializer for CopyMaterializer {
    fn materialize(&mut self, source: &Path, destination: &Path) -> Result<()> {
        fs::copy(source, destination)?;
        Ok(())
    }
}

#[derive(Default)]
struct RecordingRunner {
    outputs: VecDeque<CommandOutput>,
    requests: Vec<CommandRequest>,
    private_key: Option<(u32, String)>,
    known_hosts: Option<(u32, String)>,
    credential_paths: Vec<PathBuf>,
}

impl CommandRunner for RecordingRunner {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        if request.program.file_name().and_then(|name| name.to_str()) == Some("ssh") {
            let args = request
                .args
                .iter()
                .map(|arg| arg.to_string_lossy())
                .collect::<Vec<_>>();
            if let Some(index) = args.iter().position(|arg| arg == "-i") {
                let path = PathBuf::from(args[index + 1].as_ref());
                self.credential_paths.push(path.clone());
                self.private_key = Some((
                    fs::metadata(&path)?.permissions().mode() & 0o777,
                    fs::read_to_string(path)?,
                ));
            }
            if let Some(option) = args
                .iter()
                .find(|arg| arg.starts_with("UserKnownHostsFile="))
            {
                let path = PathBuf::from(option.trim_start_matches("UserKnownHostsFile="));
                self.credential_paths.push(path.clone());
                self.known_hosts = Some((
                    fs::metadata(&path)?.permissions().mode() & 0o777,
                    fs::read_to_string(path)?,
                ));
            }
        }
        self.requests.push(request.clone());
        self.outputs
            .pop_front()
            .ok_or_else(|| anyhow!("missing synthetic process output"))
    }
}

fn trigger_plan(dry_run: bool, stdin: Option<Vec<u8>>) -> repository::CiTriggerPlan {
    let mut request = repository::CiTriggerRequest {
        action: "deploy".to_owned(),
        sha: Some(sha("abcdef0123456789")),
        clean_mode: CiCleanMode::Auto,
        group: Some("prod; echo unsafe".to_owned()),
        hosts: None,
        nix_config: None,
        log_format: repository::CiLogFormat::Plain,
        dry_run,
        force: false,
        restart_managed: false,
        control_plane_first: false,
        verify: true,
        dirty: repository::DirtyForwarding::Clean,
    };
    if let Some(bytes) = stdin {
        request.dirty = repository::DirtyForwarding::Staged {
            patch: StagedPatch {
                base: sha("abcdef0123456789"),
                bytes,
            },
        };
    }
    repository::plan_ci_trigger(&request).unwrap()
}

#[test]
fn configured_material_is_private_and_ssh_receives_only_safe_argv_and_exact_stdin() {
    let fixture = TempDir::new().unwrap();
    let key = fixture.path().join("synthetic-key.enc");
    fs::write(&key, "SYNTHETIC PRIVATE KEY\n").unwrap();
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 22,
        private_key: Some(CiPrivateKey::Source(key)),
        known_hosts: Some("ci.example ssh-ed25519 synthetic-host-key".to_owned()),
        proxy_jump: None,
    };
    let patch = b"binary\0patch\n".to_vec();
    let plan = trigger_plan(true, Some(patch.clone()));
    let mut runner = RecordingRunner {
        outputs: VecDeque::from([CommandOutput {
            status: 17,
            stdout: b"remote stdout".to_vec(),
            stderr: b"remote stderr".to_vec(),
        }]),
        ..RecordingRunner::default()
    };
    let report = execute_ci_trigger(
        &plan,
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut runner,
        &mut CopyMaterializer,
        5,
    )
    .unwrap();

    assert_eq!(report.status, 17);
    assert!(report.dry_run);
    assert_eq!(report.stdin_bytes, patch.len());
    assert!(!report.used_keyscan);
    assert_eq!(
        runner.private_key,
        Some((0o600, "SYNTHETIC PRIVATE KEY\n".to_owned()))
    );
    assert_eq!(
        runner.known_hosts,
        Some((
            0o600,
            "ci.example ssh-ed25519 synthetic-host-key\n".to_owned()
        ))
    );
    let ssh = runner.requests.last().unwrap();
    assert_eq!(ssh.stdin.as_deref(), Some(patch.as_slice()));
    let args = ssh
        .args
        .iter()
        .map(|arg| arg.to_string_lossy())
        .collect::<Vec<_>>();
    assert!(args.iter().any(|arg| arg == "StrictHostKeyChecking=yes"));
    assert!(args.iter().any(|arg| arg == "IdentitiesOnly=yes"));
    let remote = args.last().unwrap();
    assert!(remote.starts_with("__nixbot_argv64 "));
    assert!(!remote.contains(';'));
    assert!(
        decode_argv(remote.split_once(' ').unwrap().1)
            .unwrap()
            .contains(&"prod; echo unsafe".to_owned())
    );
    assert_eq!(ssh.current_dir.as_deref(), Some(fixture.path()));
    assert!(runner.credential_paths.iter().all(|path| !path.exists()));
}

#[test]
fn absent_known_hosts_uses_bounded_keyscan_and_propagates_remote_status() {
    let fixture = TempDir::new().unwrap();
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 2222,
        private_key: None,
        known_hosts: None,
        proxy_jump: None,
    };
    let mut runner = RecordingRunner {
        outputs: VecDeque::from([
            CommandOutput::success(b"[ci.example]:2222 ssh-ed25519 scanned\n".to_vec()),
            CommandOutput {
                status: 23,
                stdout: Vec::new(),
                stderr: b"remote failed".to_vec(),
            },
        ]),
        ..RecordingRunner::default()
    };
    let report = execute_ci_trigger(
        &trigger_plan(false, None),
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut runner,
        &mut CopyMaterializer,
        7,
    )
    .unwrap();

    assert_eq!(report.status, 23);
    assert!(report.used_keyscan);
    assert_eq!(runner.requests.len(), 2);
    assert_eq!(
        runner.requests[0].args,
        ["-T", "7", "-H", "-p", "2222", "ci.example"]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
    );
    assert_eq!(runner.known_hosts.as_ref().unwrap().0, 0o600);
}

#[test]
fn empty_keyscan_result_fails_closed_without_attempting_ssh() {
    let fixture = TempDir::new().unwrap();
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 22,
        private_key: None,
        known_hosts: None,
        proxy_jump: None,
    };
    let mut runner = RecordingRunner {
        outputs: VecDeque::from([CommandOutput {
            status: 1,
            stdout: Vec::new(),
            stderr: b"scan failed".to_vec(),
        }]),
        ..RecordingRunner::default()
    };
    let error = execute_ci_trigger(
        &trigger_plan(false, None),
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut runner,
        &mut CopyMaterializer,
        5,
    )
    .unwrap_err();
    assert!(error.to_string().contains("determine CI host key"));
    assert_eq!(runner.requests.len(), 1);
}

fn executable(directory: &Path, name: &str, body: &str) -> PathBuf {
    let path = directory.join(name);
    fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[test]
fn system_executor_runs_the_argv_request_without_a_shell_wrapper() {
    let fixture = TempDir::new().unwrap();
    let trace = fixture.path().join("trace");
    let stdin = fixture.path().join("stdin");
    let ssh = executable(
        fixture.path(),
        "ssh",
        &format!(
            "printf '%s\\n' \"$@\" > '{}'; cat > '{}'; exit 9",
            trace.display(),
            stdin.display()
        ),
    );
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 22,
        private_key: None,
        known_hosts: Some("ci.example ssh-ed25519 configured".to_owned()),
        proxy_jump: None,
    };
    let payload = b"synthetic patch".to_vec();
    let report = execute_ci_trigger(
        &trigger_plan(false, Some(payload.clone())),
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new(ssh, "ssh-keyscan"),
        &mut SystemCiExecutor,
        &mut CopyMaterializer,
        5,
    )
    .unwrap();

    assert_eq!(report.status, 9);
    assert_eq!(fs::read(stdin).unwrap(), payload);
    let args = fs::read_to_string(trace).unwrap();
    assert!(args.contains("nixbot@ci.example"));
    assert!(args.contains("__nixbot_argv64"));
}

#[test]
fn process_repository_source_uses_read_only_git_argv_and_captures_binary_stdin_bytes() {
    let fixture = TempDir::new().unwrap();
    let full = b"abcdef0123456789abcdef0123456789abcdef01\n".to_vec();
    let mut source = ProcessCiRepositorySource::new(
        "git",
        RecordingRunner {
            outputs: VecDeque::from([
                CommandOutput::success(full.clone()),
                CommandOutput {
                    status: 1,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                },
                CommandOutput::success(b"GIT binary patch\0bytes".to_vec()),
                CommandOutput::success(full),
            ]),
            ..RecordingRunner::default()
        },
    );

    assert_eq!(
        source.resolve_commit(fixture.path(), "HEAD").unwrap(),
        sha("abcdef0123456789abcdef0123456789abcdef01")
    );
    let patch = source
        .capture_staged_patch(fixture.path())
        .unwrap()
        .unwrap();
    assert_eq!(patch.bytes, b"GIT binary patch\0bytes");
    let requests = &source.runner().requests;
    assert_eq!(requests.len(), 4);
    assert_eq!(
        requests[0].args,
        ["rev-parse", "--verify", "HEAD^{commit}"]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
    );
    assert!(
        requests
            .iter()
            .all(|request| request.current_dir.as_deref() == Some(fixture.path()))
    );
    assert!(requests.iter().all(|request| request.stdin.is_none()));
}

#[test]
fn age_key_materializer_uses_declared_identity_and_private_output_lifecycle() {
    let fixture = TempDir::new().unwrap();
    let source = fixture.path().join("synthetic.age");
    let identity = fixture.path().join("synthetic.identity");
    fs::write(&source, "SYNTHETIC DECRYPTED KEY\n").unwrap();
    fs::write(&identity, "synthetic identity marker").unwrap();
    let age = executable(fixture.path(), "age", "cp \"$6\" \"$5\"");
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 22,
        private_key: Some(CiPrivateKey::Source(source)),
        known_hosts: Some("ci.example ssh-ed25519 configured".to_owned()),
        proxy_jump: None,
    };
    let mut runner = RecordingRunner {
        outputs: VecDeque::from([CommandOutput::success(Vec::new())]),
        ..RecordingRunner::default()
    };
    execute_ci_trigger(
        &trigger_plan(false, None),
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut runner,
        &mut AgeOrFileCredentialMaterializer {
            age_program: age,
            identities: vec![identity],
        },
        5,
    )
    .unwrap();

    assert_eq!(
        runner.private_key,
        Some((0o600, "SYNTHETIC DECRYPTED KEY\n".to_owned()))
    );
    assert!(runner.credential_paths.iter().all(|path| !path.exists()));
}

#[test]
fn empty_inline_private_key_is_rejected_before_ssh() {
    let fixture = TempDir::new().unwrap();
    let connection = ci_runtime::CiConnection {
        inventory_name: None,
        target: "ci.example".to_owned(),
        user: "nixbot".to_owned(),
        port: 22,
        private_key: Some(CiPrivateKey::Inline(" \n".to_owned())),
        known_hosts: Some("ci.example ssh-ed25519 configured".to_owned()),
        proxy_jump: None,
    };
    let mut runner = RecordingRunner::default();
    let error = execute_ci_trigger(
        &trigger_plan(false, None),
        &connection,
        fixture.path(),
        fixture.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut runner,
        &mut CopyMaterializer,
        5,
    )
    .unwrap_err();
    assert!(error.to_string().contains("private key is empty"));
    assert!(runner.requests.is_empty());
}

#[test]
fn log_format_and_host_selection_are_derived_from_existing_cli_contracts() {
    let options = Options {
        host: Some("one".to_owned()),
        groups: vec!["prod".to_owned()],
        log_format: LogFormat::GithubActions,
        ..Options::default()
    };
    let selection = ci_runtime::forwarded_selection(&options, &inventory()).unwrap();
    assert_eq!(selection.group.as_deref(), Some("prod"));
    assert_eq!(
        selection.hosts,
        Some(CiHostSelection::Singular("one".to_owned()))
    );
    assert_eq!(
        ci_runtime::forwarded_log_format(options.log_format),
        repository::CiLogFormat::GithubActions
    );
}
