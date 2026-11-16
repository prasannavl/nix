use super::*;
use crate::fleet::inventory::Host;
use crate::fleet::selection::{SelectionOptions, select};

fn inventory() -> Inventory {
    Inventory {
        hosts: BTreeMap::from([("app".to_owned(), Host::default())]),
        ..Inventory::default()
    }
}

#[test]
fn preparation_selects_exact_candidate_without_rollback_snapshot() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["prepare"])?;
    let inventory = inventory();
    let selection = select(&inventory, &SelectionOptions::default())?;
    let mut effects = NativeFleetEffects::new(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
    )?;
    let closure = NixStorePath::closure_output("/nix/store/aaaaaaaa-nixos-system-app")?;
    effects.closures.insert("app".to_owned(), closure.clone());
    let candidate = effects.candidate_for_acquisition("app")?.unwrap();
    assert_eq!(candidate.closure, closure);
    assert!(effects.snapshots.is_empty());
    assert!(effects.activated.is_empty());
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::new(
            HostMilestone::Built,
            HostQualifier::Incomplete(HostStage::Acquire)
        )
    );
    effects.acquired.insert("app".to_owned(), closure);
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::ok(HostMilestone::Acquired)
    );
    effects.acquisition_deferred.insert("app".to_owned());
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::new(
            HostMilestone::Built,
            HostQualifier::Deferred(HostStage::Acquire)
        )
    );
    effects.deploy_failed.insert("app".to_owned());
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::failed(HostMilestone::Built, HostStage::Acquire)
    );
    Ok(())
}

#[test]
fn preparation_preserves_build_evidence_for_a_configured_acquire_skip() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["prepare"])?;
    let mut inventory = inventory();
    inventory.hosts.get_mut("app").unwrap().deploy = DeployMode::Skip;
    let selection = select(&inventory, &SelectionOptions::default())?;
    let mut effects = NativeFleetEffects::new(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
    )?;
    effects.closures.insert(
        "app".to_owned(),
        NixStorePath::closure_output("/nix/store/aaaaaaaa-nixos-system-app")?,
    );
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Acquire))
    );
    effects.closures.remove("app");
    effects.build_failed.insert("app".to_owned());
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::failed(HostMilestone::None, HostStage::Build)
    );
    Ok(())
}

#[test]
fn deployment_still_requires_its_own_snapshot() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["deploy"])?;
    let inventory = inventory();
    let selection = select(&inventory, &SelectionOptions::default())?;
    let mut effects = NativeFleetEffects::new(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
    )?;
    effects.closures.insert(
        "app".to_owned(),
        NixStorePath::closure_output("/nix/store/aaaaaaaa-nixos-system-app")?,
    );
    assert!(effects.candidate_for_acquisition("app").is_err());
    Ok(())
}

#[test]
fn preparation_dry_acquisition_never_records_a_prepared_host() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["prepare", "--dry"])?;
    let inventory = inventory();
    let selection = select(&inventory, &SelectionOptions::default())?;
    let mut effects = NativeFleetEffects::new(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
    )?;
    effects.run_phase(Phase::Acquire)?;
    assert!(effects.acquired.is_empty());
    assert!(effects.candidate_leases.is_empty());
    assert!(effects.snapshots.is_empty());
    assert!(effects.activated.is_empty());
    assert_eq!(
        effects.preparation_summary("app", false),
        FinalHostState::new(HostMilestone::Built, HostQualifier::DryRun)
    );
    Ok(())
}

#[test]
fn optional_acquisition_failure_with_a_lease_does_not_stop_other_hosts() -> Result<()> {
    let outcome = AcquireTaskOutcome {
        host: "app".into(),
        policy: DeployMode::Optional,
        result: Err(anyhow!("prefetch failed")),
        candidate_lease: Some(NixStorePath::closure_output("/nix/store/aaaaaaaa-system")?),
        acquired: None,
        deferred: false,
    };
    assert!(!outcome.stops_admission());
    let required = AcquireTaskOutcome {
        policy: DeployMode::Strict,
        ..outcome
    };
    assert!(required.stops_admission());
    Ok(())
}

#[test]
fn cleanup_failure_retains_interruption_and_never_turns_success_into_prepared() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["prepare"])?;
    let inventory = inventory();
    let selection = select(&inventory, &SelectionOptions::default())?;
    let mut effects = NativeFleetEffects::new(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
    )?;
    effects.candidate_leases.insert(
        "app".into(),
        NixStorePath::closure_output("/nix/store/aaaaaaaa-system")?,
    );
    let result = effects
        .verify_candidate_cleanup(Err(
            super::super::signal::Interrupted::from_status(130).into()
        ))
        .unwrap_err();
    assert_eq!(
        result
            .downcast_ref::<super::super::signal::Interrupted>()
            .unwrap()
            .status(),
        130
    );
    assert!(
        result
            .to_string()
            .contains("candidate lease cleanup incomplete for app")
    );
    assert!(effects.verify_candidate_cleanup(Ok(())).is_err());
    effects.candidate_leases.clear();
    assert!(effects.verify_candidate_cleanup(Ok(())).is_ok());
    Ok(())
}

#[test]
fn root_execution_preserves_retained_authority_and_checks_withdrawal_before_effects() -> Result<()>
{
    let directory = tempfile::tempdir()?;
    let invocation = Invocation::parse_canonical(["deploy", "--strategy=agent"])?;
    let inventory = inventory();
    let selection = select(&inventory, &SelectionOptions::default())?;
    assert!(
        NativeFleetEffects::new(
            &invocation,
            Path::new("/unused-nix"),
            directory.path(),
            &inventory,
            &selection,
        )
        .is_err()
    );
    let withdrawn = || bail!("fixture: durable parent withdrew deployment");
    let mut effects = NativeFleetEffects::with_owned_handoff(
        &invocation,
        Path::new("/unused-nix"),
        directory.path(),
        &inventory,
        &selection,
        OwnedHandoff {
            closures: BTreeMap::new(),
            boot: BTreeMap::new(),
            builder: "app".into(),
            cache: CacheSource::new("https://cache.invalid", Vec::<String>::new())?,
            runtime: directory.path().to_owned(),
        },
        &directory.path().join("diagnostics"),
    )?
    .with_forward_work(ForwardWorkGuard::new(&withdrawn))?;
    let error = effects.execute().unwrap_err();
    assert_eq!(
        error.to_string(),
        "fixture: durable parent withdrew deployment"
    );
    assert!(effects.phase_results.is_empty());
    assert!(effects.activated.is_empty());
    Ok(())
}
