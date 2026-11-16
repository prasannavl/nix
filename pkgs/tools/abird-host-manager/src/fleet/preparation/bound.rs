//! Metadata binding for the admitted worker. No admission, Nix execution,
//! filesystem trust, source verification or GC authority is granted here.

use std::collections::{BTreeMap, BTreeSet};

use abird_host_agent::build_executor::context::{BuildAction, InputLocation, InputTree, PlanJobs};
use abird_host_agent::build_executor::preparation::{
    self, Disposition, PreparedInputs, PreparedTarget, ResolvedTarget,
};
use abird_host_agent::build_executor::request::{
    BuildRequest, BuildTarget, Selection as IntentSelection,
};
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, bail, ensure};

use super::{
    InventoryContext, InventoryEvaluator, PlanCatalog, Routes, load_inventory, plan_targets,
    select_inventory,
};
use crate::fleet::build::NixStorePath;
use crate::fleet::cli::{Action, JobCount, Options};
use crate::fleet::inventory::Inventory;

/// Paths have structural validation only. The role must independently verify
/// exact source/patch/NARs, directory confinement and retention before effects.
pub struct RetainedTrees {
    pub source: String,
    pub snapshots: BTreeMap<String, String>,
}

pub struct InputWitnesses {
    pub tree_digest: String,
    pub protection_digest: String,
    /// Original captured identity, not reconstructed from planning.
    pub caller_repository:
        Option<abird_host_agent::build_executor::native_intent::CallerRepository>,
}

/// Original evaluated planning, restored without source access or evaluation.
pub struct Restored {
    pub inventory: Inventory,
    pub catalog: PlanCatalog,
    pub selection: crate::fleet::selection::Selection,
    /// Host → `boot.isContainer`; present only for deployment preparation.
    pub activation: BTreeMap<String, bool>,
    layers: serde_json::Value,
    context: InventoryContext,
}

impl Restored {
    /// The ordinary inventory loader over retained layers and the actual
    /// dependency result: caller-side route resolution, no source evaluation.
    pub fn inventory_with(&self, routes: Routes<'_>) -> Result<Inventory> {
        ensure!(
            !self.layers.is_null(),
            "retained planning predates inventory layers; deployment needs a new run"
        );
        load_inventory(&mut RetainedLayers(&self.layers), &self.context, routes)
    }
}

struct RetainedLayers<'a>(&'a serde_json::Value);

impl InventoryEvaluator for RetainedLayers<'_> {
    fn layers(
        &mut self,
        _: &InventoryContext,
    ) -> Result<(
        serde_json::Value,
        serde_json::Value,
        Option<serde_json::Value>,
    )> {
        let overlay = Some(self.0["overlay"].clone()).filter(|value| !value.is_null());
        Ok(super::snapshot::merge_layers(
            self.0["base"].clone(),
            overlay,
        ))
    }

    fn dependencies(&mut self, _: &InventoryContext, _: &str) -> Result<serde_json::Value> {
        Ok(self.0["dependencies"].clone())
    }
}

pub struct BoundPreparation {
    request: BuildRequest,
    trees: RetainedTrees,
    context: InventoryContext,
    build_repository: std::path::PathBuf,
    options: Options,
    action: Action,
}

impl BoundPreparation {
    pub fn new(request: BuildRequest, trees: RetainedTrees) -> Result<Self> {
        request.validate()?;
        let IntentSelection::Fleet {
            groups,
            host,
            hosts,
            nix_config,
            control_plane_first,
        } = &request.selection
        else {
            bail!("native worker requires fleet selection intent");
        };
        let evaluation = &request.evaluation;
        ensure!(
            trees
                .snapshots
                .keys()
                .map(String::as_str)
                .collect::<BTreeSet<_>>()
                == evaluation.context_digests(),
            "retained context differs from intent"
        );
        ensure!(
            trees
                .snapshots
                .iter()
                .filter(|(hash, _)| evaluation.snapshot_digests().contains(hash.as_str()))
                .map(|(_, path)| path)
                .collect::<BTreeSet<_>>()
                .len()
                == evaluation.snapshot_digests().len(),
            "different NAR digests bind the same context path"
        );
        InputLocation::source("").resolve(&trees.source, &trees.snapshots)?;
        let resolve = |input: &InputLocation| input.resolve(&trees.source, &trees.snapshots);
        let build_repository = resolve(&evaluation.build_flake)?;
        let context = InventoryContext {
            config: resolve(&evaluation.inventory)?,
            overlay: evaluation.overlay.as_ref().map(resolve).transpose()?,
            repository_config: evaluation
                .repository_config
                .as_ref()
                .map(resolve)
                .transpose()?,
            dependency_repository: resolve(&evaluation.dependency_flake)?,
        };
        let mut options = Options {
            strategy: abird_host_agent::build_executor::strategy::Strategy::Agent,
            strategy_explicit: true,
            groups: groups.clone(),
            host: host.clone(),
            hosts: hosts.clone(),
            nix_config: nix_config.clone(),
            control_plane_first: *control_plane_first,
            required_hosts: request.required_hosts.clone(),
            build_plan_jobs: match evaluation.plan_jobs {
                PlanJobs::Auto => JobCount::Auto,
                PlanJobs::Count { jobs } => JobCount::Count(usize::from(jobs)),
            },
            ..Options::default()
        };
        if let Some(jobs) = evaluation.deploy_jobs_per_domain {
            options.deploy_jobs_per_domain = usize::from(jobs);
            options.deploy_jobs_per_domain_explicit = true;
        }
        let action = match evaluation.action {
            BuildAction::Run => Action::Run,
            BuildAction::Deploy => Action::Deploy,
            BuildAction::Build => Action::Build,
            BuildAction::DevBuild => Action::DevBuild,
        };
        Ok(Self {
            request,
            trees,
            context,
            build_repository,
            options,
            action,
        })
    }

    /// Trusted installed adapter supplies a sealed native Git view separately
    /// from the verified filtered store tree. Inventory remains exact-NAR;
    /// build/dependency flakes retain native Git metadata instead of path-flake
    /// normalization. This constructor grants no source/coherence authority.
    pub fn with_native_source(
        request: BuildRequest,
        trees: RetainedTrees,
        native: &std::path::Path,
    ) -> Result<Self> {
        ensure!(
            native.is_absolute()
                && native.components().all(|part| matches!(
                    part,
                    std::path::Component::RootDir | std::path::Component::Normal(_)
                )),
            "invalid native source location"
        );
        let mut value = Self::new(request, trees)?;
        if matches!(value.request.evaluation.build_flake.tree, InputTree::Source) {
            value.build_repository = native.join(&value.request.evaluation.build_flake.relative);
        }
        if matches!(
            value.request.evaluation.dependency_flake.tree,
            InputTree::Source
        ) {
            value.context.dependency_repository =
                native.join(&value.request.evaluation.dependency_flake.relative);
        }
        Ok(value)
    }

    pub fn with_native_roots(
        input: &abird_host_agent::build_executor::preparation::worker::Input,
    ) -> Result<Self> {
        input.validate()?;
        let mut value = Self::new(
            input.request.clone(),
            RetainedTrees {
                source: input.source.path.clone(),
                snapshots: input.context_sources(),
            },
        )?;
        let resolve = |location: &InputLocation| -> Result<std::path::PathBuf> {
            Ok(input.native_root(location)?.0.join(&location.relative))
        };
        value.build_repository = resolve(&input.request.evaluation.build_flake)?;
        value.context.dependency_repository = resolve(&input.request.evaluation.dependency_flake)?;
        Ok(value)
    }

    pub fn build_repository(&self) -> &std::path::Path {
        &self.build_repository
    }

    pub fn context(&self) -> &InventoryContext {
        &self.context
    }
    pub fn options(&self) -> &Options {
        &self.options
    }
    pub fn action(&self) -> &Action {
        &self.action
    }

    /// Decode original evaluated data; no repository access or Nix query. The
    /// preparation digest binds this private capsule, but does not authorize
    /// deployment, resolve current routes or prove consumer-root validity.
    pub fn restore_planning(
        &self,
        planning: &abird_host_agent::build_executor::preparation::worker::Planning,
        prepared: &PreparedInputs,
    ) -> Result<Restored> {
        prepared.validate(&self.request)?;
        planning.validate(prepared)?;
        ensure!(
            planning.request == self.request,
            "retained resolved request differs"
        );
        let inventory: Inventory = serde_json::from_value(planning.inventory.clone())
            .map_err(|_| anyhow::anyhow!("invalid retained inventory"))?;
        ensure!(
            serde_json::to_value(&inventory)? == planning.inventory,
            "retained inventory encoding differs"
        );
        let selection = select_inventory(&inventory, &self.options)?;
        ensure!(
            selection.matches_retained(&planning.selection)?,
            "retained native selection differs"
        );
        let catalog = PlanCatalog::from_probe(
            !planning.catalog.is_null(),
            &serde_json::to_string(&planning.catalog)?,
        )?;
        let derivations = prepared
            .targets
            .iter()
            .map(|target| {
                Ok((
                    target.target.host.clone(),
                    NixStorePath::derivation(&target.derivation)?,
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        let mut expected = self.candidate(
            &inventory,
            &catalog,
            &derivations,
            InputWitnesses {
                tree_digest: prepared.tree_digest.clone(),
                protection_digest: prepared.protection_digest.clone(),
                caller_repository: prepared.caller_repository.clone(),
            },
        )?;
        expected.planning_digest = Some(planning.digest()?);
        ensure!(
            expected == *prepared,
            "retained planning differs from prepared inputs"
        );
        let restored = Restored {
            inventory,
            catalog,
            selection,
            activation: planning.activation.clone(),
            layers: planning.layers.clone(),
            context: self.context.clone(),
        };
        // Layers must reproduce exactly the evaluated (route-validated) inventory.
        if !restored.layers.is_null() {
            ensure!(
                restored.inventory_with(Routes::ValidateOnly)? == restored.inventory,
                "retained inventory layers differ from evaluated inventory"
            );
        }
        Ok(restored)
    }

    /// Complete candidate only. Partial evaluation remains a failed/unfinished
    /// job with separately retained partial results, never fabricated targets.
    /// Caller must independently verify all witnesses before record_prepared.
    pub fn candidate(
        &self,
        inventory: &Inventory,
        catalog: &PlanCatalog,
        derivations: &BTreeMap<String, NixStorePath>,
        witnesses: InputWitnesses,
    ) -> Result<PreparedInputs> {
        let selection = select_inventory(inventory, &self.options)?;
        let plans = plan_targets(inventory, &selection, &self.action, &self.options, catalog)?;
        let expected = plans
            .iter()
            .filter(|plan| !plan.skipped)
            .map(|plan| plan.host.as_str())
            .collect::<BTreeSet<_>>();
        ensure!(
            expected == derivations.keys().map(String::as_str).collect(),
            "evaluated derivations do not cover exactly the buildable selection"
        );
        let mut resolved = Vec::new();
        let mut targets = Vec::new();
        for plan in plans {
            resolved.push(ResolvedTarget {
                host: plan.host.clone(),
                configuration: plan.configuration.clone(),
                disposition: if plan.skipped {
                    Disposition::NoNativePlan
                } else {
                    Disposition::Build
                },
            });
            if !plan.skipped {
                targets.push(PreparedTarget {
                    derivation: derivations
                        .get(&plan.host)
                        .context("missing evaluated derivation")?
                        .as_str()
                        .to_owned(),
                    target: BuildTarget {
                        host: plan.host,
                        configuration: plan.configuration,
                        outputs: vec!["out".into()],
                    },
                });
            }
        }
        let inputs = PreparedInputs {
            version: preparation::VERSION,
            attempt_id: self.request.attempt_id()?,
            spec_digest: self.request.digest()?,
            source_path: self.trees.source.clone(),
            tree_digest: witnesses.tree_digest,
            evaluation_digest: self.request.evaluation.digest()?,
            context_sources: self.trees.snapshots.clone(),
            caller_repository: witnesses.caller_repository,
            resolved,
            targets,
            required_hosts: self.request.required_hosts.clone(),
            selection_digest: digest_bytes(&serde_json::to_vec(&selection)?),
            planning_digest: None,
            protection_digest: witnesses.protection_digest,
        };
        inputs.validate(&self.request)?;
        Ok(inputs)
    }
}

#[cfg(test)]
mod tests;
