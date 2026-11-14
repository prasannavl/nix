//! Disposable admitted-worker qualification, never installed by the package.
//! Candidates lack Git provenance and protection proof; never journal them.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use abird_host_agent::build_executor::request::{BuildRequest, MAX_REQUEST_BYTES};
use abird_host_agent::build_executor::workload;
use abird_host_manager::fleet::build::{
    CommandSpec, build_plan_evaluation_command, build_plan_probe_command,
};
use abird_host_manager::fleet::host_runtime::{
    DryRun, EffectKind, HostRuntime, SystemProcessRunner,
};
use abird_host_manager::fleet::preparation::bound::{
    BoundPreparation, InputWitnesses, RetainedTrees,
};
use abird_host_manager::fleet::preparation::snapshot::{InventoryCommands, NarSnapshot};
use abird_host_manager::fleet::preparation::{
    InventoryContext, InventoryEvaluator, PlanCatalog, Routes, load_inventory, plan_targets,
    select_inventory,
};
use abird_host_manager::fleet::task::InternalTask;
use abird_host_manager::programs::nix::Nix;
use anyhow::{Context, Result, bail, ensure};

#[path = "build_prepare/repository.rs"]
mod repository_fixture;

struct SnapshotProbe {
    program: PathBuf,
    source: PathBuf,
    snapshot: NarSnapshot,
    nix: Nix,
    runtime: HostRuntime<SystemProcessRunner>,
}

impl SnapshotProbe {
    fn commands(
        &self,
        context: &InventoryContext,
        snapshot: &NarSnapshot,
    ) -> Result<InventoryCommands> {
        let locate = |path: &Path| {
            snapshot.location(
                path.strip_prefix(&self.source)?
                    .to_str()
                    .context("fixture path must be UTF-8")?,
            )
        };
        InventoryCommands::new(
            &self.program,
            &locate(&context.config)?,
            context.overlay.as_deref().map(locate).transpose()?.as_ref(),
            context
                .repository_config
                .as_deref()
                .map(locate)
                .transpose()?
                .as_ref(),
        )
    }

    fn reject_bad_inputs(&mut self, context: &InventoryContext) -> Result<()> {
        let wrong = NarSnapshot::new(self.source.to_string_lossy().into_owned(), &"0".repeat(64))?;
        let bad = self.commands(context, &wrong)?;
        let output = self.runtime.execute_local_command(
            &bad.base,
            EffectKind::Build,
            InternalTask::new("bad-nar"),
        )?;
        ensure!(
            !output.succeeded() && output.stderr.contains("NAR hash mismatch"),
            "wrong NAR was not rejected"
        );
        let mut ambient = self.commands(context, &self.snapshot)?.base;
        *ambient.args.last_mut().context("missing expression")? =
            "builtins.readFile /etc/hostname".into();
        let output = self.runtime.execute_local_command(
            &ambient,
            EffectKind::Build,
            InternalTask::new("ambient-read"),
        )?;
        ensure!(
            !output.succeeded() && output.stderr.contains("forbidden in pure evaluation mode"),
            "ambient read was not rejected"
        );
        println!("SNAPSHOT_NAR_AND_AMBIENT_REJECTED");
        Ok(())
    }
}

impl InventoryEvaluator for SnapshotProbe {
    fn layers(
        &mut self,
        context: &InventoryContext,
    ) -> Result<(
        serde_json::Value,
        serde_json::Value,
        Option<serde_json::Value>,
    )> {
        self.commands(context, &self.snapshot)?.evaluate(|command| {
            let output = self.runtime.execute_local_command(
                command,
                EffectKind::Build,
                InternalTask::new("snapshot-inventory"),
            )?;
            ensure!(
                output.succeeded(),
                "snapshot inventory failed: {}",
                output.stderr
            );
            serde_json::from_str(&output.stdout).context("parse snapshot inventory")
        })
    }

    fn dependencies(&mut self, context: &InventoryContext, key: &str) -> Result<serde_json::Value> {
        self.nix.dependencies(context, key)
    }
}

fn read_request() -> Result<BuildRequest> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(MAX_REQUEST_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    BuildRequest::decode(&bytes)
}

fn main() -> Result<()> {
    workload::require_wrapper_placement()?;
    ensure!(
        unsafe { libc::geteuid() } == 1000,
        "fixture requires unprivileged builder"
    );
    ensure!(
        std::env::var("NIX_REMOTE")?.as_str() == "daemon",
        "shared daemon required"
    );
    let mut args = std::env::args().skip(1);
    let first = args.next().context("Nix or fixture mode required")?;
    if first == "--repository-fixture" {
        return repository_fixture::run(args);
    }
    let nix = PathBuf::from(first);
    let source = args.next().context("source required")?;
    ensure!(args.next().is_none(), "unexpected fixture argument");
    ensure!(
        !Path::new(&source).join(".git").exists(),
        "fixture must lack Git metadata"
    );
    let request = read_request()?;
    let case = request.id.nonce.clone();
    ensure!(
        [
            "native-base",
            "native-overlay",
            "native-config",
            "native-partial",
            "native-fallback"
        ]
        .contains(&case.as_str()),
        "unknown fixture case"
    );
    let bound = BoundPreparation::new(
        request.clone(),
        RetainedTrees {
            source: source.clone(),
            snapshots: BTreeMap::new(),
        },
    )?;
    let mut runtime = HostRuntime::new(
        SystemProcessRunner,
        bound.build_repository().to_owned(),
        DryRun::No,
    )?;
    let hashed = runtime.execute_local_command(
        &CommandSpec::new(
            nix.to_string_lossy(),
            ["hash", "path", "--type", "sha256", "--base16", &source].map(str::to_owned),
        ),
        EffectKind::ReadOnly,
        InternalTask::new("native-source-nar"),
    )?;
    ensure!(hashed.succeeded(), "source NAR hashing failed");
    let mut evaluator = SnapshotProbe {
        program: nix.clone(),
        source: PathBuf::from(&source),
        snapshot: NarSnapshot::new(source.clone(), hashed.stdout.trim())?,
        nix: Nix::new(&nix)?,
        runtime,
    };
    if case == "native-base" {
        evaluator.reject_bad_inputs(bound.context())?;
    }
    let inventory = load_inventory(&mut evaluator, bound.context(), Routes::ValidateOnly)?;
    let mut runtime = evaluator.runtime;
    ensure!(
        inventory.hosts["app"].deps == ["db"],
        "dependency context lost"
    );
    if bound.context().overlay.is_some() {
        ensure!(
            inventory.hosts["app"].target.as_deref() == Some("operator-override"),
            "overlay lost"
        );
    }
    let selection = select_inventory(&inventory, bound.options())?;
    let nix_args = vec!["--store".into(), "daemon".into()];
    let probe = runtime.execute_local_command(
        &build_plan_probe_command(&nix.to_string_lossy(), &nix_args),
        EffectKind::ReadOnly,
        InternalTask::new("native-probe"),
    )?;
    let catalog = PlanCatalog::from_probe(probe.succeeded(), &probe.stdout)?;
    ensure!(
        matches!(catalog, PlanCatalog::Native(_)) == (case != "native-fallback"),
        "wrong catalog"
    );
    let targets = plan_targets(
        &inventory,
        &selection,
        bound.action(),
        bound.options(),
        &catalog,
    )?;
    let mut derivations = BTreeMap::new();
    let (mut failed, mut skipped) = (0, 0);
    for target in targets {
        if target.skipped {
            skipped += 1;
            continue;
        }
        let result = runtime.evaluate_build_plan(
            &build_plan_evaluation_command(
                &nix.to_string_lossy(),
                &nix_args,
                catalog.attribute(),
                &target.configuration,
            ),
            InternalTask::new(format!("native-plan-{}", target.host)),
        );
        match result {
            Ok(result) => {
                let drv = result
                    .executed()
                    .context("evaluation unexpectedly suppressed")?;
                ensure!(
                    Path::new(drv.as_str()).is_file(),
                    "missing evaluated derivation"
                );
                let output = runtime.execute_local_command(
                    &CommandSpec::new(
                        nix.parent()
                            .context("Nix bin missing")?
                            .join("nix-store")
                            .to_string_lossy(),
                        ["--store", "daemon", "--query", "--outputs", drv.as_str()]
                            .map(str::to_owned),
                    ),
                    EffectKind::ReadOnly,
                    InternalTask::new("native-unbuilt-outputs"),
                )?;
                ensure!(
                    output.succeeded() && !output.stdout.trim().is_empty(),
                    "invalid drv"
                );
                for path in output.stdout.lines() {
                    ensure!(
                        path.starts_with("/nix/store/") && !Path::new(path).exists(),
                        "preparation realized output"
                    );
                }
                derivations.insert(target.host, drv);
            }
            Err(_) => failed += 1,
        }
    }
    let candidate = bound.candidate(
        &inventory,
        &catalog,
        &derivations,
        InputWitnesses {
            tree_digest: hashed.stdout.trim().into(),
            // Deliberately synthetic: not a protection/GC receipt.
            protection_digest: "d".repeat(64),
            caller_repository: None,
        },
    );
    let expected = match case.as_str() {
        "native-overlay" => (0, 0, 1),
        "native-partial" => (1, 1, 0),
        _ => (2, 0, 0),
    };
    ensure!(
        (derivations.len(), failed, skipped) == expected,
        "wrong native evaluation results"
    );
    if case == "native-partial" {
        ensure!(
            candidate.is_err(),
            "partial results became a complete candidate"
        );
        println!("NATIVE_PREPARATION_PARTIAL evaluated=1 failed=1");
        bail!("fixture partial evaluation; no prepared receipt");
    }
    let candidate = candidate?;
    candidate.validate(&request)?;
    ensure!(
        candidate.spec_digest == request.digest()?,
        "request binding lost"
    );
    println!(
        "NATIVE_PREPARATION_READY case={case} evaluated={} skipped={skipped}",
        derivations.len()
    );
    Ok(())
}
