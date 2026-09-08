use std::path::{Path, PathBuf};

use abird_host_manager::fleet::terraform::{
    AutomaticTfvars, BackendKind, BackendValues, ChangeDecision, ChangeGateInput, DiffObservation,
    EnvironmentRequirement, ProcessCommand, ProjectPlanInput, SecretLoad, TerraformAction,
    TerraformError, TerraformPhase, backend_config_args, evaluate_change_gate,
    inject_automatic_tfvars, is_candidate_path, plan_project_commands, plan_tofu_wrapper_command,
    project_context, project_environment_contract, projects_for_action, resolve_wrapper_context,
    select_tfvar_secret_paths, validate_tofu_wrapper_invocation,
};

fn argv(command: &ProcessCommand) -> Vec<&str> {
    command
        .args
        .iter()
        .map(|argument| argument.value.as_str())
        .collect()
}

fn r2_values() -> BackendValues {
    BackendValues {
        r2_account_id: Some("account".to_owned()),
        r2_state_bucket: Some("state".to_owned()),
        r2_access_key_id: Some("access".to_owned()),
        r2_secret_access_key: Some("secret".to_owned()),
        ..BackendValues::default()
    }
}

#[test]
fn actions_preserve_configured_phase_and_project_order() {
    let all = projects_for_action(&TerraformAction::Tf, None).unwrap();
    assert_eq!(
        all.iter()
            .map(|project| project.name.as_str())
            .collect::<Vec<_>>(),
        ["cloudflare-dns", "cloudflare-platform", "cloudflare-apps"]
    );
    assert_eq!(
        all.iter().map(|project| project.phase).collect::<Vec<_>>(),
        [
            TerraformPhase::Dns,
            TerraformPhase::Platform,
            TerraformPhase::Apps,
        ]
    );

    for (action, expected) in [
        (TerraformAction::TfDns, vec!["cloudflare-dns"]),
        (TerraformAction::TfPlatform, vec!["cloudflare-platform"]),
        (TerraformAction::TfApps, vec!["cloudflare-apps"]),
        (
            TerraformAction::TfProject("cloudflare-platform".to_owned()),
            vec!["cloudflare-platform"],
        ),
    ] {
        let projects = projects_for_action(&action, None).unwrap();
        assert_eq!(
            projects
                .iter()
                .map(|project| project.name.as_str())
                .collect::<Vec<_>>(),
            expected
        );
    }

    assert_eq!(
        projects_for_action(&TerraformAction::TfProject("gcp-platform".to_owned()), None,),
        Err(TerraformError::UnconfiguredProject(
            "gcp-platform".to_owned()
        ))
    );
    assert!(
        projects_for_action(&TerraformAction::Tofu(vec!["plan".to_owned()]), None)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn work_dir_override_selects_only_its_matching_phase() {
    let override_dir = Path::new("/checkout/tf/gcp-platform");
    let projects = projects_for_action(&TerraformAction::Tf, Some(override_dir)).unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].name, "gcp-platform");
    assert_eq!(projects[0].phase, TerraformPhase::Platform);
    assert_eq!(projects[0].directory, Path::new("tf/gcp-platform"));

    assert!(
        projects_for_action(&TerraformAction::TfDns, Some(override_dir))
            .unwrap()
            .is_empty()
    );
}

#[test]
fn project_provider_and_backend_mapping_preserves_special_case() {
    let cloudflare = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    assert_eq!(cloudflare.name, "cloudflare-dns");
    assert_eq!(cloudflare.provider, "cloudflare");
    assert_eq!(cloudflare.backend, BackendKind::R2);

    let bootstrap = project_context(Path::new("/repo/tf/gcp-bootstrap")).unwrap();
    assert_eq!(bootstrap.provider, "gcp");
    assert_eq!(bootstrap.backend, BackendKind::R2);

    let gcp = project_context(Path::new("/repo/tf/gcp-platform")).unwrap();
    assert_eq!(gcp.backend, BackendKind::Gcs);

    assert_eq!(
        project_context(Path::new("/repo/tf/acme-platform")),
        Err(TerraformError::UnsupportedBackend(
            "acme-platform".to_owned()
        ))
    );
}

#[test]
fn environment_contract_declares_only_names_paths_and_load_modes() {
    let cloudflare = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    let contract = project_environment_contract(&cloudflare);
    assert_eq!(
        contract
            .iter()
            .map(|declaration| declaration.name.as_str())
            .collect::<Vec<_>>(),
        [
            "R2_ACCOUNT_ID",
            "R2_STATE_BUCKET",
            "R2_ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY",
            "R2_STATE_KEY",
            "CLOUDFLARE_API_TOKEN",
        ]
    );
    assert_eq!(
        contract[0].secret_path.as_deref(),
        Some(Path::new(
            "data/secrets/globals/cloudflare/r2-account-id.key.age"
        ))
    );
    assert_eq!(contract[0].load, Some(SecretLoad::Value));
    assert_eq!(contract[0].requirement, EnvironmentRequirement::Required);
    assert_eq!(contract[4].secret_path, None);
    assert_eq!(contract[4].requirement, EnvironmentRequirement::Optional);

    let gcp = project_context(Path::new("/repo/tf/gcp-platform")).unwrap();
    let contract = project_environment_contract(&gcp);
    assert_eq!(
        contract
            .iter()
            .map(|declaration| declaration.name.as_str())
            .collect::<Vec<_>>(),
        [
            "GCP_STATE_BUCKET",
            "GCP_STATE_PREFIX",
            "GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT",
            "GOOGLE_APPLICATION_CREDENTIALS",
        ]
    );
    assert_eq!(contract[3].load, Some(SecretLoad::Path));
    assert_eq!(
        contract[3].requirement,
        EnvironmentRequirement::RequiredFile
    );
}

#[test]
fn backend_arguments_are_complete_ordered_and_mark_credentials_sensitive() {
    let project = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    let args = backend_config_args(&project, &r2_values()).unwrap();
    assert_eq!(
        args.iter()
            .map(|argument| argument.value.as_str())
            .collect::<Vec<_>>(),
        [
            "-backend-config=bucket=state",
            "-backend-config=key=cloudflare-dns/terraform.tfstate",
            "-backend-config=region=auto",
            "-backend-config=endpoint=https://account.r2.cloudflarestorage.com",
            "-backend-config=access_key=access",
            "-backend-config=secret_key=secret",
            "-backend-config=skip_credentials_validation=true",
            "-backend-config=skip_region_validation=true",
            "-backend-config=skip_requesting_account_id=true",
            "-backend-config=use_path_style=true",
        ]
    );
    assert!(!args[0].sensitive);
    assert!(args[4].sensitive);
    assert!(args[5].sensitive);

    let gcp = project_context(Path::new("/repo/tf/gcp-platform")).unwrap();
    let args = backend_config_args(
        &gcp,
        &BackendValues {
            gcp_state_bucket: Some("gcp-state".to_owned()),
            gcp_state_prefix: Some("custom/prefix".to_owned()),
            gcp_backend_impersonate_service_account: Some("tf@example.test".to_owned()),
            ..BackendValues::default()
        },
    )
    .unwrap();
    assert_eq!(
        args.iter()
            .map(|argument| argument.value.as_str())
            .collect::<Vec<_>>(),
        [
            "-backend-config=bucket=gcp-state",
            "-backend-config=prefix=custom/prefix",
            "-backend-config=impersonate_service_account=tf@example.test",
        ]
    );
}

#[test]
fn missing_required_backend_environment_fails_before_command_planning() {
    let project = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    assert_eq!(
        backend_config_args(&project, &BackendValues::default()),
        Err(TerraformError::MissingEnvironment("R2_ACCOUNT_ID"))
    );
}

#[test]
fn change_candidates_match_project_provider_backend_and_apps_inputs() {
    for path in [
        "tf/cloudflare-platform/main.tf",
        "tf/modules/cloudflare/access.tf",
        "data/secrets/globals/cloudflare/api-token.key.age",
        "data/secrets/globals/tf/cloudflare.tfvars.age",
        "data/secrets/globals/tf/cloudflare/one.tfvars.age",
        "data/secrets/globals/tf/cloudflare-platform.tfvars.age",
        "data/secrets/globals/tf/cloudflare-platform/one.tfvars.age",
        "data/secrets/globals/cloudflare/r2-state-bucket.key.age",
    ] {
        assert!(
            is_candidate_path(
                TerraformPhase::Platform,
                "cloudflare-platform",
                Path::new(path)
            ),
            "expected candidate path: {path}"
        );
    }
    assert!(!is_candidate_path(
        TerraformPhase::Platform,
        "cloudflare-platform",
        Path::new("tf/cloudflare-dns/main.tf")
    ));
    assert!(is_candidate_path(
        TerraformPhase::Apps,
        "cloudflare-apps",
        Path::new("services/llmug-hello/default.nix")
    ));
    assert!(!is_candidate_path(
        TerraformPhase::Dns,
        "cloudflare-dns",
        Path::new("services/llmug-hello/default.nix")
    ));
}

#[test]
fn change_gate_is_fail_open_and_checks_worktree_after_committed_diff() {
    let base = ChangeGateInput {
        if_changed: true,
        target_ref: "HEAD".to_owned(),
        target_available: true,
        base_ref: Some("HEAD^1".to_owned()),
        diff: DiffObservation::Available(Vec::new()),
        worktree_paths: Vec::new(),
    };

    assert_eq!(
        evaluate_change_gate(TerraformPhase::Dns, "cloudflare-dns", &base),
        ChangeDecision::SkipUnchanged
    );
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                if_changed: false,
                ..base.clone()
            }
        ),
        ChangeDecision::RunForce
    ));
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                target_available: false,
                ..base.clone()
            }
        ),
        ChangeDecision::RunTargetUnavailable { target_ref } if target_ref == "HEAD"
    ));
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                base_ref: None,
                ..base.clone()
            }
        ),
        ChangeDecision::RunBaseUnavailable { target_ref } if target_ref == "HEAD"
    ));
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                diff: DiffObservation::Failed,
                ..base.clone()
            }
        ),
        ChangeDecision::RunDiffFailed { range } if range == "HEAD^1..HEAD"
    ));
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                diff: DiffObservation::Available(vec![PathBuf::from(
                    "tf/cloudflare-dns/main.tf"
                )]),
                ..base.clone()
            }
        ),
        ChangeDecision::RunDiffChanged { path }
            if path == Path::new("tf/cloudflare-dns/main.tf")
    ));
    assert!(matches!(
        evaluate_change_gate(
            TerraformPhase::Dns,
            "cloudflare-dns",
            &ChangeGateInput {
                worktree_paths: vec![PathBuf::from(
                    "data/secrets/globals/tf/cloudflare-dns/local.tfvars.age"
                )],
                ..base
            }
        ),
        ChangeDecision::RunWorktreeChanged { path }
            if path == Path::new(
                "data/secrets/globals/tf/cloudflare-dns/local.tfvars.age"
            )
    ));
}

#[test]
fn automatic_tfvars_are_filtered_deduplicated_sorted_and_inserted_after_subcommand() {
    let discovered = select_tfvar_secret_paths(
        "cloudflare-platform",
        [
            PathBuf::from("data/secrets/globals/tf/cloudflare-platform/z.tfvars.age"),
            PathBuf::from("data/secrets/globals/tf/cloudflare/a.tfvars.age"),
            PathBuf::from("data/secrets/globals/tf/cloudflare-platform/z.tfvars.age"),
            PathBuf::from("data/secrets/globals/tf/cloudflare-dns/no.tfvars.age"),
            PathBuf::from("data/secrets/globals/tf/cloudflare/readme.txt"),
        ],
    );
    assert_eq!(
        discovered,
        [
            PathBuf::from("data/secrets/globals/tf/cloudflare/a.tfvars.age"),
            PathBuf::from("data/secrets/globals/tf/cloudflare-platform/z.tfvars.age"),
        ]
    );

    let args = inject_automatic_tfvars(
        &[
            "-chdir=tf/cloudflare-platform".to_owned(),
            "plan".to_owned(),
            "saved-position".to_owned(),
        ],
        &AutomaticTfvars {
            discovered_secret_paths: discovered,
            materialized_var_files: vec![
                PathBuf::from("/run/nixbot/a.tfvars"),
                PathBuf::from("/run/nixbot/z.tfvars"),
            ],
        },
        true,
    )
    .unwrap();
    assert_eq!(
        args,
        [
            "-chdir=tf/cloudflare-platform",
            "plan",
            "-var-file=/run/nixbot/a.tfvars",
            "-var-file=/run/nixbot/z.tfvars",
            "saved-position",
        ]
    );
}

#[test]
fn explicit_vars_or_unsupported_subcommands_disable_auto_tfvars() {
    let tfvars = AutomaticTfvars {
        discovered_secret_paths: vec![PathBuf::from("secret.tfvars.age")],
        materialized_var_files: vec![PathBuf::from("/run/secret.tfvars")],
    };
    for args in [
        vec!["plan".to_owned(), "-var=answer=42".to_owned()],
        vec!["init".to_owned()],
        vec!["output".to_owned()],
    ] {
        assert_eq!(inject_automatic_tfvars(&args, &tfvars, true).unwrap(), args);
    }
    assert_eq!(
        inject_automatic_tfvars(&["plan".to_owned()], &AutomaticTfvars::default(), true),
        Err(TerraformError::MissingSecretTfvars {
            subcommand: "plan".to_owned(),
        })
    );
    assert_eq!(
        inject_automatic_tfvars(&["console".to_owned()], &AutomaticTfvars::default(), true,)
            .unwrap(),
        ["console"]
    );
}

#[test]
fn wrapper_context_uses_chdir_or_current_directory_and_recognizes_repo_projects() {
    let relative = resolve_wrapper_context(
        Path::new("/repo"),
        &[
            "-chdir=tf/cloudflare-platform".to_owned(),
            "plan".to_owned(),
        ],
    )
    .unwrap();
    assert_eq!(
        relative.directory,
        Path::new("/repo/tf/cloudflare-platform")
    );
    assert_eq!(relative.project.unwrap().name, "cloudflare-platform");

    let split = resolve_wrapper_context(
        Path::new("/repo"),
        &[
            "-chdir".to_owned(),
            "/repo/tf/gcp-platform".to_owned(),
            "plan".to_owned(),
        ],
    )
    .unwrap();
    assert_eq!(split.project.unwrap().backend, BackendKind::Gcs);

    let generic = resolve_wrapper_context(Path::new("/repo"), &["version".to_owned()]).unwrap();
    assert_eq!(generic.directory, Path::new("/repo"));
    assert_eq!(generic.project, None);
}

#[test]
fn tofu_wrapper_is_nonempty_and_local_only() {
    assert_eq!(
        validate_tofu_wrapper_invocation(&[], None),
        Err(TerraformError::MissingTofuArguments)
    );
    assert_eq!(
        validate_tofu_wrapper_invocation(&["plan".to_owned()], Some("nixbot tofu plan")),
        Err(TerraformError::RemoteTofuUnsupported)
    );
    validate_tofu_wrapper_invocation(&["plan".to_owned()], None).unwrap();
}

#[test]
fn project_command_plan_is_directly_executable_and_preserves_saved_plan_boundary() {
    let project = project_context(Path::new("/repo/tf/cloudflare-apps")).unwrap();
    let commands = plan_project_commands(&ProjectPlanInput {
        repo_root: PathBuf::from("/repo"),
        project,
        backend_values: r2_values(),
        automatic_tfvars: AutomaticTfvars {
            discovered_secret_paths: vec![PathBuf::from("encrypted.tfvars.age")],
            materialized_var_files: vec![PathBuf::from("/run/nixbot/apps.tfvars")],
        },
        project_requires_secret_tfvars: true,
        dry_run: false,
        plan_file: PathBuf::from("/run/nixbot/tfplan.123"),
        apps_package_default: Some(PathBuf::from("pkgs/cloudflare-apps/default.nix")),
    })
    .unwrap();

    assert_eq!(commands.len(), 4);
    assert_eq!(commands[0].program, "nix");
    assert_eq!(
        argv(&commands[0]),
        [
            "build",
            "--file",
            "pkgs/cloudflare-apps/default.nix",
            "--no-link"
        ]
    );
    assert_eq!(
        &argv(&commands[1])[0..3],
        [
            "-chdir=/repo/tf/cloudflare-apps",
            "init",
            "-lockfile=readonly"
        ]
    );
    assert_eq!(
        argv(&commands[2]),
        [
            "-chdir=/repo/tf/cloudflare-apps",
            "plan",
            "-var-file=/run/nixbot/apps.tfvars",
            "-input=false",
            "-out=/run/nixbot/tfplan.123",
        ]
    );
    assert_eq!(
        argv(&commands[3]),
        [
            "-chdir=/repo/tf/cloudflare-apps",
            "apply",
            "-input=false",
            "-auto-approve",
            "/run/nixbot/tfplan.123",
        ]
    );
    assert!(
        commands
            .iter()
            .all(|command| { command.current_dir.as_deref() == Some(Path::new("/repo")) })
    );
    assert_eq!(
        commands[1].redacted_argv()[7..9],
        [
            "-backend-config=access_key=<redacted>",
            "-backend-config=secret_key=<redacted>"
        ]
    );
}

#[test]
fn dry_run_plans_without_saved_plan_or_apply() {
    let project = project_context(Path::new("/repo/tf/cloudflare-dns")).unwrap();
    let commands = plan_project_commands(&ProjectPlanInput {
        repo_root: PathBuf::from("/repo"),
        project,
        backend_values: r2_values(),
        automatic_tfvars: AutomaticTfvars::default(),
        project_requires_secret_tfvars: false,
        dry_run: true,
        plan_file: PathBuf::from("/unused"),
        apps_package_default: None,
    })
    .unwrap();
    assert_eq!(commands.len(), 2);
    assert_eq!(argv(&commands[1])[1..], ["plan", "-input=false"]);
}

#[test]
fn tofu_wrapper_appends_backend_only_for_init_without_explicit_config() {
    let plan = plan_tofu_wrapper_command(
        Path::new("/repo"),
        &[
            "-chdir=tf/cloudflare-dns".to_owned(),
            "init".to_owned(),
            "-lockfile=readonly".to_owned(),
        ],
        &r2_values(),
        &AutomaticTfvars::default(),
        false,
        None,
    )
    .unwrap();
    assert_eq!(plan.context.project.unwrap().name, "cloudflare-dns");
    assert_eq!(plan.command.program, "tofu");
    assert_eq!(argv(&plan.command).len(), 13);
    assert!(argv(&plan.command)[3].starts_with("-backend-config=bucket="));
    assert_eq!(
        plan.command.redacted_argv()[7..9],
        [
            "-backend-config=access_key=<redacted>",
            "-backend-config=secret_key=<redacted>"
        ]
    );

    let explicit = plan_tofu_wrapper_command(
        Path::new("/repo"),
        &[
            "-chdir=tf/cloudflare-dns".to_owned(),
            "init".to_owned(),
            "-backend-config=custom.hcl".to_owned(),
        ],
        &r2_values(),
        &AutomaticTfvars::default(),
        false,
        None,
    )
    .unwrap();
    assert_eq!(
        argv(&explicit.command),
        [
            "-chdir=tf/cloudflare-dns",
            "init",
            "-backend-config=custom.hcl"
        ]
    );
}
