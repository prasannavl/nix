//! Installed unprivileged preparation helper. Shared native inventory, selection
//! and planning only; no root journal access, admission, realization or replay.
//! Parent owns sealed inputs, credentials, producer settlement and original cap.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::context::{InputLocation, InputTree};
use abird_host_agent::build_executor::preparation::worker::{
    Consumed, Consumption, FAILURE_DIAGNOSTICS, Input, Output, Query, QueryKind, value_digest,
};
use abird_host_agent::build_executor::process::Runner;
use abird_host_agent::build_executor::workload;
use anyhow::{Context, Result, ensure};
use serde_json::Value;

use super::bound::{BoundPreparation, InputWitnesses};
use super::snapshot::{
    InventoryExpression, InventoryExpressions, NarSnapshot, SnapshotLocation, uri_part,
};
use super::{
    InventoryContext, InventoryEvaluator, PlanCatalog, Routes, load_inventory, plan_targets,
    select_inventory,
};
use crate::fleet::build::{NixStorePath, query::FlakeQuery};

struct Native {
    program: PathBuf,
    evaluation_library: PathBuf,
    manager_program: PathBuf,
    build_reference: String,
    evaluation: Option<super::native_api::Session>,
    environment: Vec<(OsString, OsString)>,
    sources: BTreeMap<PathBuf, NarSnapshot>,
    runner: Runner,
    poisoned: bool,
    flakes: BTreeMap<PathBuf, Flake>,
    input: Input,
    consumed: Consumption,
    /// Raw layers and actual dependency result, retained for caller routing.
    layers: serde_json::Map<String, Value>,
}

struct Flake {
    reference: String,
    location: InputLocation,
}

impl Native {
    /// Upstream adapter query. Consumed-source evidence is the adapter's
    /// fetcher-produced/mounted root binding; output Selection never enters it.
    fn flake_value(&mut self, query: FlakeQuery, cwd: &Path, kind: QueryKind) -> Result<Value> {
        let result = (|| {
            ensure!(!self.poisoned, "preparation observation unresolved");
            let flake = self
                .flakes
                .get(cwd)
                .context("unbound native flake location")?;
            let request = super::native_api::Request {
                version: 2,
                program: self.program.clone(),
                reference: flake.reference.clone(),
                system: self.input.native_system.clone(),
                query,
            };
            let location = flake.location.clone();
            self.runner.check_ready()?;
            let bytes = if request.reference == self.build_reference {
                if self.evaluation.is_none() {
                    self.evaluation = Some(super::native_api::Session::open(
                        &request,
                        &self.evaluation_library,
                        cwd,
                    )?);
                    self.runner.check_ready()?;
                }
                self.evaluation
                    .as_mut()
                    .context("native root missing")?
                    .query(&request.query)?
            } else {
                // A distinct dependency flake has one query, before the build
                // root. Keep its global registry/nixConfig state in its own
                // existing worker, not a second root in the build evaluator.
                ensure!(
                    kind == QueryKind::Dependencies && self.evaluation.is_none(),
                    "unexpected independent native root"
                );
                let mut command = Command::new(&self.manager_program);
                command
                    .arg(abird_host_agent::build_executor::role::ManagerCommand::Query.argument())
                    .arg(&self.evaluation_library)
                    .current_dir(cwd)
                    .env_clear()
                    .envs(self.environment.iter().cloned());
                let output = self
                    .runner
                    .run(&mut command, &serde_json::to_vec(&request)?)?;
                ensure!(
                    output.status.success(),
                    "{}",
                    abird_host_agent::build_executor::preparation::worker::failure_diagnostic(
                        &output.stderr
                    )
                    .unwrap_or(FAILURE_DIAGNOSTICS[3])
                );
                output.stdout
            };
            self.runner.check_ready()?;
            let observed: super::native_api::Observation = serde_json::from_slice(&bytes)?;
            ensure!(observed.version == 2, "unsupported native API observation");
            observed
                .selection
                .validate(kind == QueryKind::Catalog, &self.input.native_system)?;
            let attribute = observed.selection.attribute().map(str::to_owned);
            let result_digest = value_digest(&observed.selection.result)?;
            self.consumed
                .observe(
                    &self.input,
                    Consumed {
                        location: location.clone(),
                        source_info: observed.source_info.into(),
                    },
                    Query {
                        kind,
                        location,
                        attribute,
                        result_digest,
                        inputs: observed.inputs,
                    },
                )
                .context(FAILURE_DIAGNOSTICS[4])?;
            Ok(observed.selection.result)
        })();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn inventory_value(&mut self, expression: &InventoryExpression) -> Result<Value> {
        let result = (|| {
            ensure!(
                !self.poisoned && self.evaluation.is_none(),
                "inventory evaluation follows an unresolved/retained root"
            );
            let request = super::native_api::InventoryRequest::new(
                &self.program,
                &self.input.native_system,
                expression,
            )?;
            let mut child = Command::new(&self.manager_program);
            child
                .arg(abird_host_agent::build_executor::role::ManagerCommand::Query.argument())
                .arg(&self.evaluation_library)
                .current_dir("/var/empty")
                .env_clear()
                .envs(self.environment.iter().cloned());
            let captured = self
                .runner
                .run(&mut child, &serde_json::to_vec(&request)?)?;
            ensure!(captured.status.success(), "native inventory worker failed");
            serde_json::from_slice(&captured.stdout).context("invalid native inventory JSON")
        })();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn location(&self, path: &Path) -> Result<SnapshotLocation> {
        for (root, source) in &self.sources {
            if let Ok(relative) = path.strip_prefix(root) {
                return source.location(relative.to_str().context("non-UTF8 inventory location")?);
            }
        }
        anyhow::bail!("inventory location outside retained snapshots")
    }
}

impl InventoryEvaluator for Native {
    fn layers(&mut self, context: &InventoryContext) -> Result<(Value, Value, Option<Value>)> {
        let expressions = InventoryExpressions::new(
            &self.location(&context.config)?,
            context
                .overlay
                .as_ref()
                .map(|path| self.location(path))
                .transpose()?
                .as_ref(),
            context
                .repository_config
                .as_ref()
                .map(|path| self.location(path))
                .transpose()?
                .as_ref(),
        )?;
        let layers = expressions.evaluate(|expression| self.inventory_value(expression))?;
        ensure!(self.layers.is_empty(), "inventory layers evaluated twice");
        self.layers.insert("base".into(), layers.1.clone());
        self.layers
            .insert("overlay".into(), layers.2.clone().unwrap_or(Value::Null));
        Ok(layers)
    }

    fn dependencies(&mut self, context: &InventoryContext, key: &str) -> Result<Value> {
        let value = self
            .flake_value(
                FlakeQuery::value(key),
                &context.dependency_repository,
                QueryKind::Dependencies,
            )
            .context(FAILURE_DIAGNOSTICS[2])?;
        ensure!(
            self.layers.len() == 2,
            "dependencies precede retained inventory layers"
        );
        self.layers.insert("dependencies".into(), value.clone());
        Ok(value)
    }
}

/// Input is a root-to-helper message, not an independently trusted source claim.
/// A separately invoked helper cannot publish preparation or verified outcomes.
pub fn prepare(input: Input, program: PathBuf, evaluation_library: PathBuf) -> Result<Output> {
    input.validate()?;
    workload::require_wrapper_placement()?;
    let uid = unsafe { libc::geteuid() };
    ensure!(
        uid > 0 && uid < u32::MAX,
        "preparation must be unprivileged"
    );
    ensure!(
        program.is_absolute()
            && program.starts_with("/nix/store")
            && program.file_name().is_some_and(|name| name == "nix"),
        "invalid installed native program"
    );
    // Standalone clone (`.git` directory) or relocated caller linked worktree
    // (`.git` file); upstream resolves either, never a path: flake.
    ensure!(
        std::fs::symlink_metadata(input.native_source.join(".git"))
            .is_ok_and(|metadata| metadata.is_dir() || metadata.is_file()),
        "native source lacks Git metadata"
    );
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(input.budget_millis))
        .context("helper deadline overflow")?;
    let mut environment = Vec::new();
    for name in [
        "HOME",
        "LC_ALL",
        "PATH",
        "NIX_CONF_DIR",
        "NIX_CONFIG",
        "NIX_SSL_CERT_FILE",
        "GIT_CONFIG_GLOBAL",
        "GIT_OPTIONAL_LOCKS",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
    ] {
        environment.push((
            OsString::from(name),
            std::env::var_os(name).context("installed preparation environment missing")?,
        ));
    }
    if let Some(value) = std::env::var_os("GIT_CONFIG_NOSYSTEM") {
        environment.push(("GIT_CONFIG_NOSYSTEM".into(), value));
    }
    let mut sources = BTreeMap::new();
    for (hash, path) in &input.snapshots {
        sources.insert(PathBuf::from(path), NarSnapshot::new(path.clone(), hash)?);
    }
    for source in input
        .native_roots
        .values()
        .map(|root| &root.source)
        .chain(std::iter::once(&input.source))
    {
        // Inventory may live in the independently imported Git root too.
        sources.insert(
            PathBuf::from(&source.path),
            NarSnapshot::new(source.path.clone(), &source.nar_digest)?,
        );
    }
    let locate_flake = |location: &InputLocation| -> Result<Flake> {
        match &location.tree {
            InputTree::Source | InputTree::Git { .. } => {
                // Upstream's git scheme keeps a URL `narHash` query inside
                // `url` and never verifies it. Use the plain native reference;
                // the adapter reports the actual mounted root, which must equal
                // the protected imported tree (checked in Consumed::validate).
                let reference = format!(
                    "git+file://{}{}",
                    uri_part(
                        input
                            .native_root(location)?
                            .0
                            .to_str()
                            .context("non-UTF8 native source")?
                    ),
                    if location.relative.is_empty() {
                        String::new()
                    } else {
                        format!("?dir={}", uri_part(&location.relative))
                    }
                );
                Ok(Flake {
                    reference,
                    location: location.clone(),
                })
            }
            InputTree::Snapshot { .. } => {
                anyhow::bail!("external native flake lacks its own Git context")
            }
        }
    };
    let build_flake = locate_flake(&input.request.evaluation.build_flake)?;
    let dependency_flake = locate_flake(&input.request.evaluation.dependency_flake)?;
    let bound = BoundPreparation::with_native_roots(&input)?;
    if bound.build_repository() == bound.context().dependency_repository {
        ensure!(
            build_flake.location == dependency_flake.location
                && build_flake.reference == dependency_flake.reference,
            "native flake aliases differ"
        );
    }
    let mut native = Native {
        program,
        evaluation_library,
        manager_program: std::env::current_exe()?,
        build_reference: build_flake.reference.clone(),
        evaluation: None,
        environment,
        sources,
        poisoned: false,
        input: input.clone(),
        consumed: Consumption::default(),
        layers: serde_json::Map::new(),
        flakes: BTreeMap::from([
            (bound.build_repository().to_owned(), build_flake),
            (
                bound.context().dependency_repository.clone(),
                dependency_flake,
            ),
        ]),
        runner: Runner::new(uid, super::native_api::QUERY_LIMITS, deadline)?,
    };
    let inventory = load_inventory(&mut native, bound.context(), Routes::ValidateOnly)
        .context(FAILURE_DIAGNOSTICS[1])?;
    let selection =
        select_inventory(&inventory, bound.options()).context(FAILURE_DIAGNOSTICS[5])?;
    let probe = native.flake_value(
        FlakeQuery::catalog(),
        bound.build_repository(),
        QueryKind::Catalog,
    )?;
    // Only positively observed catalog absence selects native fallback. Failure,
    // malformed JSON, context mismatch or transport loss always propagates.
    let catalog = PlanCatalog::from_probe(!probe.is_null(), &serde_json::to_string(&probe)?)?;
    let mut derivations = BTreeMap::new();
    let planned = plan_targets(
        &inventory,
        &selection,
        bound.action(),
        bound.options(),
        &catalog,
    )
    .context(FAILURE_DIAGNOSTICS[6])?;
    for target in planned.iter().cloned() {
        if target.skipped {
            continue;
        }
        let output = native.flake_value(
            FlakeQuery::derivation(catalog.attribute(), &target.configuration),
            bound.build_repository(),
            QueryKind::Derivation {
                host: target.host.clone(),
            },
        )?;
        let path = output
            .as_str()
            .context("invalid native derivation encoding")?;
        ensure!(
            !path.contains(char::is_whitespace) && path.ends_with(".drv"),
            "invalid native derivation receipt"
        );
        derivations.insert(target.host, NixStorePath::derivation(path)?);
    }
    // Same retained root, after every derivation: the per-host fact activation
    // and rollback would otherwise re-evaluate (`nix eval .#nixosConfigurations
    // .<cfg>.config.boot.isContainer`), with the CLI's attribute resolution.
    let mut activation = BTreeMap::new();
    if abird_host_agent::build_executor::preparation::worker::needs_activation(&input.request) {
        for target in planned.iter().filter(|target| !target.skipped) {
            let fact = native.flake_value(
                FlakeQuery::value(format!(
                    "nixosConfigurations.{}.config.boot.isContainer",
                    target.configuration
                )),
                bound.build_repository(),
                QueryKind::Activation {
                    host: target.host.clone(),
                },
            )?;
            activation.insert(
                target.host.clone(),
                fact.as_bool()
                    .context("boot.isContainer is not a boolean")?,
            );
        }
    }
    ensure!(!native.poisoned, "preparation observation unresolved");
    native.runner.check_ready()?;
    // Parent's actual input-root witness; root worker extends it with evaluated
    // derivations only after this producer stage has positively settled.
    let mut prepared = bound.candidate(
        &inventory,
        &catalog,
        &derivations,
        InputWitnesses {
            tree_digest: input.source.nar_digest.clone(),
            protection_digest: input.protection_digest.clone(),
            caller_repository: input.caller_repository.clone(),
        },
    )?;
    let planning = abird_host_agent::build_executor::preparation::worker::Planning {
        version: 1,
        request: input.request.clone(),
        inventory: serde_json::to_value(&inventory)?,
        catalog: probe,
        selection: serde_json::to_string(&selection)?,
        activation,
        layers: Value::Object(std::mem::take(&mut native.layers)),
    };
    prepared.planning_digest = Some(planning.digest()?);
    let output = Output {
        version: 3,
        prepared,
        consumed: native.consumed,
        planning: Some(planning),
    };
    output.validate(&input).context(FAILURE_DIAGNOSTICS[7])?;
    Ok(output)
}
