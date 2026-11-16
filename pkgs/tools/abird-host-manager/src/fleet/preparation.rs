//! Shared native inventory and build-plan preparation.
//!
//! Inputs are explicit, not sealed: the owned worker must independently bind
//! source/context, admission, placement and GC exclusion before evaluating.
//! No authority, realization, retry or deployment effects live here.

pub mod bound;
pub mod executor;
pub mod native_api;
pub mod repository;
pub mod snapshot;
pub mod source;
pub mod source_executor;
pub(in crate::fleet) mod source_scope;

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::programs::nix::Nix;

use super::build::BuildPlanAttribute;
use super::cli::{Action, Options};
use super::inventory::{DeployMode, Inventory};
use super::inventory_routing::{self, RouteRequest, RouteSource, SelfIdentity};
use super::selection::{Selection, SelectionOptions, select};

/// Resolved inputs; no cwd, Git-ancestor or sibling-overlay discovery.
/// The dependency flake may differ from the build source (external inventory).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InventoryContext {
    pub config: PathBuf,
    pub overlay: Option<PathBuf>,
    pub repository_config: Option<PathBuf>,
    pub dependency_repository: PathBuf,
}

impl InventoryContext {
    fn validate(&self) -> Result<()> {
        for path in [
            Some(&self.config),
            self.overlay.as_ref(),
            self.repository_config.as_ref(),
            Some(&self.dependency_repository),
        ]
        .into_iter()
        .flatten()
        {
            if !path.is_absolute() {
                bail!("inventory context paths must be absolute");
            }
        }
        Ok(())
    }
}

pub enum Routes<'a> {
    ValidateOnly,
    Resolve {
        request: RouteRequest,
        source: RouteSource,
        identity: Option<&'a SelfIdentity>,
    },
}

/// Effect boundary; owned adapters must account for these Nix effects too.
pub trait InventoryEvaluator {
    fn layers(&mut self, context: &InventoryContext) -> Result<(Value, Value, Option<Value>)>;
    fn dependencies(&mut self, context: &InventoryContext, key: &str) -> Result<Value>;
}

impl InventoryEvaluator for Nix {
    fn layers(&mut self, context: &InventoryContext) -> Result<(Value, Value, Option<Value>)> {
        self.eval_inventory_file_with_overlay_layers_json(
            &context.config,
            context.overlay.as_deref(),
            context.repository_config.as_deref(),
        )
    }

    fn dependencies(&mut self, context: &InventoryContext, key: &str) -> Result<Value> {
        self.eval_installable_json(&context.dependency_repository, &format!(".#{key}"))
    }
}

pub fn load_inventory(
    evaluator: &mut impl InventoryEvaluator,
    context: &InventoryContext,
    routes: Routes<'_>,
) -> Result<Inventory> {
    context.validate()?;
    let (mut value, base, override_value) = evaluator
        .layers(context)
        .with_context(|| format!("evaluate fleet inventory {}", context.config.display()))?;
    let route_decision = match routes {
        Routes::Resolve {
            request,
            source,
            identity,
        } => Some(inventory_routing::apply_named_routes_with_source(
            &mut value,
            &base,
            override_value.as_ref(),
            request,
            source,
            identity,
        )?),
        Routes::ValidateOnly => {
            inventory_routing::validate_named_routes(&value, &base, override_value.as_ref())?;
            None
        }
    };
    let mut inventory: Inventory = serde_json::from_value(value)
        .with_context(|| format!("decode fleet inventory {}", context.config.display()))?;
    inventory.route_decision = route_decision;
    let key = inventory
        .config
        .deploy_deps_key
        .as_deref()
        .unwrap_or("nixbot.deployDependencies");
    if key.is_empty()
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        bail!("config.deployDepsKey must be a non-empty flake attribute path");
    }
    let dependencies = evaluator
        .dependencies(context, key)
        .with_context(|| format!("evaluate deploy dependency attribute {key}"))?;
    inventory.apply_deploy_dependencies(
        serde_json::from_value::<BTreeMap<String, Vec<String>>>(dependencies)
            .context("decode evaluated deploy dependencies")?,
    )?;
    inventory.validate()?;
    Ok(inventory)
}

/// CLI intent overrides inventory; otherwise preserve the command default.
pub(crate) fn effective_jobs_per_domain(inventory: &Inventory, options: &Options) -> usize {
    if options.deploy_jobs_per_domain_explicit {
        options.deploy_jobs_per_domain
    } else {
        inventory
            .config
            .deploy_jobs_per_domain
            .unwrap_or(options.deploy_jobs_per_domain)
    }
}

pub fn select_inventory(inventory: &Inventory, options: &Options) -> Result<Selection> {
    let hosts_explicit = options.host.is_some() || options.hosts.is_some();
    let groups = if options.groups.is_empty() && !hosts_explicit {
        inventory
            .config
            .default_group
            .as_deref()
            .map(|raw| {
                raw.split([',', ' ', '\t', '\n'])
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    } else {
        options.groups.clone()
    };
    let hosts = options.hosts.clone().or_else(|| {
        (!hosts_explicit)
            .then(|| inventory.config.default_hosts.clone())
            .flatten()
    });
    let deploy_jobs_per_domain = effective_jobs_per_domain(inventory, options);
    if let Some(max) = options.deploy_jobs_per_domain_max
        && (max == 0 || max < deploy_jobs_per_domain)
    {
        bail!(
            "--jobs-per-domain-max ({max}) must be at least the effective per-domain jobs ({deploy_jobs_per_domain})"
        );
    }
    let selection = select(
        inventory,
        &SelectionOptions {
            groups,
            host: options.host.clone(),
            hosts,
            required_hosts: options.required_hosts.clone(),
            control_plane_first: options.control_plane_first,
        },
    )?;
    ensure_explicit_named_route_effective(inventory, selection.ordered.iter().map(String::as_str))?;
    Ok(selection)
}

pub fn ensure_explicit_named_route_effective<'a>(
    inventory: &Inventory,
    hosts: impl IntoIterator<Item = &'a str>,
) -> Result<()> {
    let Some(route) =
        inventory
            .route_decision
            .as_ref()
            .and_then(|decision| match decision.request {
                RouteRequest::Cf | RouteRequest::Ts => Some(decision.request.as_str()),
                RouteRequest::Auto | RouteRequest::Default => None,
            })
    else {
        return Ok(());
    };
    if hosts.into_iter().any(|name| {
        inventory
            .hosts
            .get(name)
            .and_then(|host| host.routing.as_ref())
            .is_some_and(|route| route.effective)
    }) {
        return Ok(());
    }
    bail!("explicit route {route} does not affect any selected host path")
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlanCatalog {
    Native(BTreeSet<String>),
    NixosConfiguration,
}

impl PlanCatalog {
    /// Match native probe semantics: failed probe uses the compatibility
    /// attribute; successful malformed output is an error, never fallback.
    pub fn from_probe(succeeded: bool, stdout: &str) -> Result<Self> {
        if succeeded {
            Ok(Self::Native(
                serde_json::from_str(stdout).context("parse native build-plan probe output")?,
            ))
        } else {
            Ok(Self::NixosConfiguration)
        }
    }

    pub fn attribute(&self) -> BuildPlanAttribute {
        match self {
            Self::Native(_) => BuildPlanAttribute::Native,
            Self::NixosConfiguration => BuildPlanAttribute::NixosConfiguration,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanTarget {
    pub host: String,
    pub configuration: String,
    pub skipped: bool,
}

/// Preserve every selected host in native order, including no-build targets.
/// No derivations are fabricated; consumers evaluate non-skipped targets with
/// `build_plan_evaluation_command` and retain each actual result separately.
pub fn plan_targets(
    inventory: &Inventory,
    selection: &Selection,
    action: &Action,
    options: &Options,
    catalog: &PlanCatalog,
) -> Result<Vec<PlanTarget>> {
    if !action.uses_build_strategy() {
        bail!("build-plan preparation requires a build action");
    }
    selection
        .ordered
        .iter()
        .map(|host| {
            let entry = inventory
                .hosts
                .get(host)
                .with_context(|| format!("unknown selected host {host}"))?;
            let configuration = if options.host.as_deref() == Some(host) {
                options.nix_config.as_ref().unwrap_or(host)
            } else {
                host
            };
            let skipped = matches!(action, Action::Run | Action::Deploy | Action::Prepare)
                && entry.deploy == DeployMode::Skip
                && matches!(catalog, PlanCatalog::Native(plans) if !plans.contains(configuration));
            Ok(PlanTarget {
                host: host.clone(),
                configuration: configuration.clone(),
                skipped,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests;
