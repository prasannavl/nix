use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use abird_host_manager::fleet::terraform::{
    AutomaticTfvars, ChangeDecision, ChangeGateInput, DiffObservation, EnvironmentDeclaration,
    EnvironmentRequirement, ProcessArgument, ProcessCommand, ProjectRun, SecretLoad,
    TerraformAction, TerraformPhase, project_context,
};
use abird_host_manager::fleet::terraform_runtime::{
    ChangeGateSource, CommandExecutor, CopySafeOutput, Decryptor, PhaseProjectStatus,
    ProjectExecution, ProjectRuntimeInput, ProjectSelection, RuntimeError, RuntimePrograms,
    SecureMaterializer, SystemCommandExecutor, discover_tfvar_secrets, execute_phase,
    materialize_tfvars, prepare_project_execution, resolve_environment,
    select_projects_for_execution, validate_project_environment,
};

fn executable(directory: &Path, name: &str, body: &str) -> PathBuf {
    let path = directory.join(name);
    fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn cloudflare_environment() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("R2_ACCOUNT_ID".to_owned(), "account".to_owned()),
        ("R2_STATE_BUCKET".to_owned(), "state".to_owned()),
        ("R2_ACCESS_KEY_ID".to_owned(), "access".to_owned()),
        ("R2_SECRET_ACCESS_KEY".to_owned(), "secret".to_owned()),
        ("CLOUDFLARE_API_TOKEN".to_owned(), "token".to_owned()),
    ])
}

#[derive(Default)]
struct CopyDecryptor;

impl Decryptor for CopyDecryptor {
    fn decrypt(&mut self, source: &Path, destination: &Path) -> Result<(), String> {
        fs::copy(source, destination)
            .map(|_| ())
            .map_err(|error| error.to_string())
    }
}

struct PartialFailureDecryptor;

impl Decryptor for PartialFailureDecryptor {
    fn decrypt(&mut self, _source: &Path, destination: &Path) -> Result<(), String> {
        fs::write(destination, "partial plaintext").unwrap();
        Err("synthetic decryption failure".to_owned())
    }
}

#[test]
fn secure_materializer_uses_private_modes_and_cleans_its_lifecycle() {
    let fixture = TempDir::new().unwrap();
    let source = fixture.path().join("synthetic.age");
    fs::write(&source, "synthetic-value\n").unwrap();

    let root;
    {
        let mut materializer = SecureMaterializer::new(fixture.path(), CopyDecryptor).unwrap();
        root = materializer.root().to_path_buf();
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );

        let output = materializer.materialize_file(&source, "key").unwrap();
        assert_eq!(
            fs::metadata(&output).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(fs::read_to_string(output).unwrap(), "synthetic-value\n");
    }
    assert!(!root.exists());
}

#[test]
fn secure_materializer_removes_partial_plaintext_after_decryption_failure() {
    let fixture = TempDir::new().unwrap();
    let source = fixture.path().join("synthetic.age");
    fs::write(&source, "not a real secret").unwrap();
    let mut materializer =
        SecureMaterializer::new(fixture.path(), PartialFailureDecryptor).unwrap();

    assert!(matches!(
        materializer.materialize_file(&source, "key"),
        Err(RuntimeError::Decrypt { .. })
    ));
    assert_eq!(fs::read_dir(materializer.root()).unwrap().count(), 0);
}

#[test]
fn environment_resolution_prefers_existing_values_then_materializes_declared_secrets() {
    let fixture = TempDir::new().unwrap();
    fs::create_dir_all(fixture.path().join("fixtures")).unwrap();
    fs::write(fixture.path().join("fixtures/value.age"), "from-file\n\n").unwrap();
    fs::write(fixture.path().join("fixtures/path.age"), "json-fixture").unwrap();
    let declarations = vec![
        EnvironmentDeclaration {
            name: "PRESENT".to_owned(),
            secret_path: Some(PathBuf::from("fixtures/not-used.age")),
            load: Some(SecretLoad::Value),
            requirement: EnvironmentRequirement::Required,
        },
        EnvironmentDeclaration {
            name: "VALUE".to_owned(),
            secret_path: Some(PathBuf::from("fixtures/value.age")),
            load: Some(SecretLoad::Value),
            requirement: EnvironmentRequirement::Required,
        },
        EnvironmentDeclaration {
            name: "PATH".to_owned(),
            secret_path: Some(PathBuf::from("fixtures/path.age")),
            load: Some(SecretLoad::Path),
            requirement: EnvironmentRequirement::RequiredFile,
        },
        EnvironmentDeclaration {
            name: "OPTIONAL".to_owned(),
            secret_path: Some(PathBuf::from("fixtures/missing.age")),
            load: Some(SecretLoad::Value),
            requirement: EnvironmentRequirement::Optional,
        },
    ];
    let mut materializer = SecureMaterializer::new(fixture.path(), CopyDecryptor).unwrap();
    let resolved = resolve_environment(
        &declarations,
        &BTreeMap::from([("PRESENT".to_owned(), "inherited".to_owned())]),
        fixture.path(),
        &mut materializer,
    )
    .unwrap();

    assert_eq!(resolved["PRESENT"], "inherited");
    assert_eq!(resolved["VALUE"], "from-file");
    assert!(Path::new(&resolved["PATH"]).is_file());
    assert!(!resolved.contains_key("OPTIONAL"));
}

#[test]
fn backend_and_provider_environment_are_validated_before_planning() {
    let project = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    let values = validate_project_environment(&project, &cloudflare_environment()).unwrap();
    assert_eq!(values.r2_state_bucket.as_deref(), Some("state"));

    let mut missing_provider = cloudflare_environment();
    missing_provider.remove("CLOUDFLARE_API_TOKEN");
    assert_eq!(
        validate_project_environment(&project, &missing_provider),
        Err(RuntimeError::MissingEnvironment(
            "CLOUDFLARE_API_TOKEN".to_owned()
        ))
    );

    let gcp = project_context(Path::new("/repo/tf/gcp-platform")).unwrap();
    assert_eq!(
        validate_project_environment(
            &gcp,
            &BTreeMap::from([
                ("GCP_STATE_BUCKET".to_owned(), "state".to_owned()),
                (
                    "GOOGLE_APPLICATION_CREDENTIALS".to_owned(),
                    "/missing/credentials.json".to_owned(),
                ),
            ]),
        ),
        Err(RuntimeError::EnvironmentFileMissing {
            name: "GOOGLE_APPLICATION_CREDENTIALS".to_owned(),
            path: PathBuf::from("/missing/credentials.json"),
        })
    );
}

#[test]
fn tfvar_discovery_and_materialization_are_sorted_and_project_scoped() {
    let fixture = TempDir::new().unwrap();
    for relative in [
        "data/secrets/globals/tf/cloudflare/provider.tfvars.age",
        "data/secrets/globals/tf/cloudflare-platform/project.tfvars.age",
        "data/secrets/globals/tf/cloudflare-platform/readme.txt",
        "data/secrets/globals/tf/cloudflare-dns/not-ours.tfvars.age",
    ] {
        let path = fixture.path().join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, relative).unwrap();
    }

    let discovered = discover_tfvar_secrets(fixture.path(), "cloudflare-platform").unwrap();
    assert_eq!(discovered.len(), 2);
    assert_eq!(
        discovered
            .iter()
            .map(|secret| secret.declaration.as_path())
            .collect::<Vec<_>>(),
        [
            Path::new("data/secrets/globals/tf/cloudflare/provider.tfvars.age"),
            Path::new("data/secrets/globals/tf/cloudflare-platform/project.tfvars.age"),
        ]
    );

    let mut materializer = SecureMaterializer::new(fixture.path(), CopyDecryptor).unwrap();
    let tfvars = materialize_tfvars(&discovered, &mut materializer).unwrap();
    assert_eq!(tfvars.discovered_secret_paths.len(), 2);
    assert_eq!(tfvars.materialized_var_files.len(), 2);
    assert!(
        tfvars
            .materialized_var_files
            .iter()
            .all(|path| path.is_file())
    );
}

#[test]
fn system_command_execution_is_cwd_authoritative_and_redacts_args_and_output() {
    let fixture = TempDir::new().unwrap();
    let tool = executable(
        fixture.path(),
        "tool",
        "pwd; printf '%s\\n' \"$* $CLOUDFLARE_API_TOKEN\"; printf '%s\\n' \"$* $CLOUDFLARE_API_TOKEN\" >&2",
    );
    let mut executor = SystemCommandExecutor::new(RuntimePrograms::from_pairs([("tool", tool)]));
    let command = ProcessCommand {
        program: "tool".to_owned(),
        args: vec![
            ProcessArgument {
                value: "public".to_owned(),
                sensitive: false,
            },
            ProcessArgument {
                value: "-backend-config=secret_key=top-secret".to_owned(),
                sensitive: true,
            },
        ],
        current_dir: Some(fixture.path().to_path_buf()),
    };
    let environment = BTreeMap::from([(
        "CLOUDFLARE_API_TOKEN".to_owned(),
        "provider-token".to_owned(),
    )]);
    let output = executor
        .execute(fixture.path(), &command, &environment)
        .unwrap();
    assert!(output.success());
    assert!(output.stdout.contains(fixture.path().to_str().unwrap()));
    assert!(!output.stdout.contains("top-secret"));
    assert!(!output.stderr.contains("top-secret"));
    assert!(!output.stdout.contains("provider-token"));
    assert!(!output.stderr.contains("provider-token"));
    assert!(output.stdout.contains("secret_key=<redacted>"));
    assert_eq!(
        output.redacted_argv[1],
        "-backend-config=secret_key=<redacted>"
    );

    let outside = ProcessCommand {
        current_dir: Some(PathBuf::from("/different")),
        ..command
    };
    assert!(matches!(
        executor.execute(fixture.path(), &outside, &BTreeMap::new()),
        Err(RuntimeError::RepositoryCurrentDirMismatch { .. })
    ));
}

struct FakeChanges {
    observations: VecDeque<ChangeGateInput>,
}

impl ChangeGateSource for FakeChanges {
    fn collect(
        &mut self,
        _repo_root: &Path,
        _phase: TerraformPhase,
        _project: &str,
        _if_changed: bool,
        _target_ref: &str,
        _preferred_base_ref: Option<&str>,
    ) -> ChangeGateInput {
        self.observations.pop_front().unwrap()
    }
}

fn unchanged() -> ChangeGateInput {
    ChangeGateInput {
        if_changed: true,
        target_ref: "HEAD".to_owned(),
        target_available: true,
        base_ref: Some("HEAD^1".to_owned()),
        diff: DiffObservation::Available(Vec::new()),
        worktree_paths: Vec::new(),
    }
}

#[test]
fn project_selection_preserves_order_and_applies_each_change_gate() {
    let fixture = TempDir::new().unwrap();
    for name in ["cloudflare-dns", "cloudflare-platform", "cloudflare-apps"] {
        fs::create_dir_all(fixture.path().join("tf").join(name)).unwrap();
    }
    let mut changes = FakeChanges {
        observations: VecDeque::from([
            ChangeGateInput {
                diff: DiffObservation::Available(vec![PathBuf::from("tf/cloudflare-dns/main.tf")]),
                ..unchanged()
            },
            unchanged(),
            ChangeGateInput {
                worktree_paths: vec![PathBuf::from("services/app/default.nix")],
                ..unchanged()
            },
        ]),
    };
    let selected = select_projects_for_execution(
        &TerraformAction::Tf,
        None,
        fixture.path(),
        true,
        "HEAD",
        None,
        &mut changes,
    )
    .unwrap();
    assert_eq!(
        selected
            .iter()
            .map(|selection| selection.run.name.as_str())
            .collect::<Vec<_>>(),
        ["cloudflare-dns", "cloudflare-platform", "cloudflare-apps"]
    );
    assert!(matches!(
        selected[0].decision,
        ChangeDecision::RunDiffChanged { .. }
    ));
    assert_eq!(selected[1].decision, ChangeDecision::SkipUnchanged);
    assert!(matches!(
        selected[2].decision,
        ChangeDecision::RunWorktreeChanged { .. }
    ));
    assert!(
        selected
            .iter()
            .all(|selection| selection.run.directory.is_absolute())
    );
}

#[test]
fn dry_run_executes_init_and_plan_without_saved_plan_or_apply() {
    let fixture = TempDir::new().unwrap();
    let project_dir = fixture.path().join("tf/cloudflare-dns");
    fs::create_dir_all(&project_dir).unwrap();
    let trace = fixture.path().join("trace");
    let tofu = executable(
        fixture.path(),
        "tofu",
        "printf '%s\\n' \"$*\" >> \"$TRACE\"",
    );
    let selection = ProjectSelection {
        run: ProjectRun {
            name: "cloudflare-dns".to_owned(),
            phase: TerraformPhase::Dns,
            directory: project_dir,
        },
        decision: ChangeDecision::RunForce,
    };
    let mut environment = cloudflare_environment();
    environment.insert("TRACE".to_owned(), trace.display().to_string());
    let execution = prepare_project_execution(&ProjectRuntimeInput {
        selection,
        environment,
        automatic_tfvars: AutomaticTfvars::default(),
        project_requires_secret_tfvars: false,
        dry_run: true,
        plan_file: fixture.path().join("unused-plan"),
        apps_package_default: None,
        repo_root: fixture.path().to_path_buf(),
    })
    .unwrap();
    let mut executor = SystemCommandExecutor::new(RuntimePrograms::from_pairs([("tofu", tofu)]));
    let report = execute_phase(&[execution], fixture.path(), &mut executor);
    assert!(report.success);
    let lines = fs::read_to_string(trace).unwrap();
    assert_eq!(lines.lines().count(), 2);
    assert!(lines.contains(" init ") || lines.contains(" init"));
    assert!(lines.contains(" plan ") || lines.contains(" plan"));
    assert!(!lines.contains(" apply "));
    assert!(!lines.contains("-out="));
}

#[test]
fn phase_execution_skips_unchanged_and_stops_after_first_failure() {
    let fixture = TempDir::new().unwrap();
    let marker = fixture.path().join("later-ran");
    let command = |script: &str| ProcessCommand {
        program: "sh".to_owned(),
        args: vec![
            ProcessArgument {
                value: "-c".to_owned(),
                sensitive: false,
            },
            ProcessArgument {
                value: script.to_owned(),
                sensitive: false,
            },
        ],
        current_dir: Some(fixture.path().to_path_buf()),
    };
    let projects = vec![
        ProjectExecution {
            name: "skip".to_owned(),
            decision: ChangeDecision::SkipUnchanged,
            commands: vec![command("exit 99")],
            environment: BTreeMap::new(),
        },
        ProjectExecution {
            name: "fail".to_owned(),
            decision: ChangeDecision::RunForce,
            commands: vec![command("exit 7")],
            environment: BTreeMap::new(),
        },
        ProjectExecution {
            name: "later".to_owned(),
            decision: ChangeDecision::RunForce,
            commands: vec![command(&format!("touch {}", marker.display()))],
            environment: BTreeMap::new(),
        },
    ];
    let mut executor = SystemCommandExecutor::new(RuntimePrograms::from_pairs([(
        "sh",
        PathBuf::from("/bin/sh"),
    )]));
    let report = execute_phase(&projects, fixture.path(), &mut executor);
    assert!(!report.success);
    assert_eq!(report.projects[0].status, PhaseProjectStatus::Skipped);
    assert_eq!(
        report.projects[1].status,
        PhaseProjectStatus::Failed { status: Some(7) }
    );
    assert_eq!(report.projects[2].status, PhaseProjectStatus::NotRun);
    assert!(!marker.exists());
}

#[test]
fn copy_safe_output_redacts_multiple_sensitive_values_deterministically() {
    let output = CopySafeOutput::new(
        "access and secret",
        "secret then access",
        &[
            ("access".to_owned(), "<redacted>".to_owned()),
            ("secret".to_owned(), "<redacted>".to_owned()),
        ],
    );
    assert_eq!(output.stdout, "<redacted> and <redacted>");
    assert_eq!(output.stderr, "<redacted> then <redacted>");
}
