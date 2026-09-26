use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::agent_adapter::HostManagerConfig;
use crate::programs::nix::Nix;
use crate::repository::Repository;

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct ServicePlacement {
    scope: String,
    stack: String,
    owner: String,
    placement: Option<String>,
    #[serde(rename = "default")]
    default_scope: bool,
    stable: bool,
    env: Option<String>,
    address: String,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ResolvedLogicalService {
    pub scope: String,
    pub stack: String,
    pub repository_owner: String,
    pub stable: bool,
    pub host: String,
    pub resource: String,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ResolvedServiceMove {
    pub service: ResolvedLogicalService,
    pub source_resource: String,
    pub target_resource: String,
}

pub struct ServiceMoveResolutionRequest<'a> {
    pub stack: Option<&'a str>,
    pub scope: Option<&'a str>,
    pub services: &'a [String],
    pub source: &'a str,
    pub target: &'a str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ServiceMoveResolution {
    placements: Vec<ServicePlacement>,
    source_resource: String,
    target_resource: String,
}

pub fn resolve_service_moves(
    repository: &Repository,
    nix_program: &Path,
    inventory: &HostManagerConfig,
    request: ServiceMoveResolutionRequest<'_>,
) -> Result<Vec<ResolvedServiceMove>> {
    let ServiceMoveResolutionRequest {
        stack,
        scope,
        services,
        source,
        target,
    } = request;
    if let Some(stack) = stack {
        validate_registry_name("stack", stack)?;
    }
    if let Some(scope) = scope {
        validate_registry_name("scope", scope)?;
    }
    if stack.is_some() && scope.is_some() {
        bail!("--stack and --scope are mutually exclusive");
    }
    validate_registry_name("source host", source)?;
    validate_registry_name("target host", target)?;
    for service in services {
        validate_registry_name("service", service)?;
    }
    let requested_stack = serde_json::to_string(&stack)?;
    let requested_scope = serde_json::to_string(&scope)?;
    let requested_services = serde_json::to_string(services)?;
    let source_host = serde_json::to_string(source)?;
    let target_host = serde_json::to_string(target)?;
    let expression = format!(
        r#"manager: let
  requestedStack = {requested_stack};
  requestedScope = {requested_scope};
  requestedServices = {requested_services};
  sourceHost = {source_host};
  targetHost = {target_host};
  scopes = manager.scopes;
  catalog = manager.scopeCatalog;
  defaultSelection = manager.defaultSelection or null;
  stablePlacements = manager.servicePlacements.placements or {{}};
  resourceFor = host: logical: let
    resources = manager.serviceResourcesByHost.${{host}};
    matches = builtins.filter (name:
      name == logical || builtins.match ".*[-:]${{logical}}" name != null
    ) (builtins.attrNames resources);
  in if builtins.length matches == 1
     then "service:${{builtins.head matches}}"
     else throw "logical service does not resolve to exactly one host-agent resource";
  placementsFor = serviceName: let
    declaresService = scopeName: let
      stack = builtins.getAttr scopeName scopes;
    in stack ? serviceRegistry && builtins.hasAttr serviceName stack.serviceRegistry.services;
    matchesSelector = scopeName: let
      metadata = builtins.getAttr scopeName catalog;
    in if requestedScope != null
       then scopeName == requestedScope
       else requestedStack == null || metadata.stack == requestedStack;
    candidates = builtins.filter
      (scopeName: matchesSelector scopeName && declaresService scopeName)
      (builtins.attrNames scopes);
    placementFor = scopeName: let
      stack = builtins.getAttr scopeName scopes;
      metadata = builtins.getAttr scopeName catalog;
      registry = stack.serviceRegistry;
      spec = registry.serviceFor serviceName;
      group = registry.placementForService serviceName;
      endpoint = registry.endpointForGroup spec.role group;
    in {{
      scope = scopeName;
      inherit (metadata) owner placement stack;
      default = defaultSelection != null && scopeName == defaultSelection.scope;
      stable = builtins.hasAttr serviceName (stablePlacements.${{scopeName}} or {{}});
      env = stack.env or null;
      address = endpoint.address;
    }};
  in map placementFor candidates;
in builtins.listToAttrs (map (serviceName: {{
  name = serviceName;
  value = {{
    placements = placementsFor serviceName;
    source_resource = resourceFor sourceHost serviceName;
    target_resource = resourceFor targetHost serviceName;
  }};
}}) requestedServices)"#
    );
    let value = Nix::new(nix_program.to_path_buf())?.eval_installable_apply_json(
        repository.root(),
        ".#hostManager",
        &expression,
    )?;
    let mut evaluated: BTreeMap<String, ServiceMoveResolution> =
        serde_json::from_value(value).context("decode batched service move resolution")?;
    services
        .iter()
        .map(|service| {
            let resolution = evaluated
                .remove(service)
                .with_context(|| format!("Nix omitted service move resolution for {service:?}"))?;
            let placement = select_service_placement(stack, scope, service, resolution.placements)?;
            let host = inventory.host_name_for_address(&placement.address)?;
            if host != source {
                bail!(
                    "service {service:?} is declared on {host:?}, not requested source {source:?}"
                );
            }
            Ok(ResolvedServiceMove {
                service: ResolvedLogicalService {
                    scope: placement.scope,
                    stack: placement.stack,
                    repository_owner: placement.owner,
                    stable: placement.stable,
                    host: host.to_owned(),
                    resource: resolution.source_resource.clone(),
                },
                source_resource: resolution.source_resource,
                target_resource: resolution.target_resource,
            })
        })
        .collect()
}

pub fn resolve_service_host(
    repository: &Repository,
    nix_program: &Path,
    inventory: &HostManagerConfig,
    stack: Option<&str>,
    scope: Option<&str>,
    service: &str,
) -> Result<ResolvedLogicalService> {
    if let Some(stack) = stack {
        validate_registry_name("stack", stack)?;
    }
    if let Some(scope) = scope {
        validate_registry_name("scope", scope)?;
    }
    if stack.is_some() && scope.is_some() {
        bail!("--stack and --scope are mutually exclusive");
    }
    validate_registry_name("service", service)?;
    let stack_literal = serde_json::to_string(&stack).context("encode stack name for Nix")?;
    let scope_literal = serde_json::to_string(&scope).context("encode scope name for Nix")?;
    let service_literal = serde_json::to_string(service).context("encode service name for Nix")?;
    let expression = format!(
        r#"manager: let
  requestedStack = {stack_literal};
  requestedScope = {scope_literal};
  serviceName = {service_literal};
  scopes = manager.scopes;
  catalog = manager.scopeCatalog;
  defaultSelection = manager.defaultSelection or null;
  stablePlacements = manager.servicePlacements.placements or {{}};
  declaresService = scopeName: let
    stack = builtins.getAttr scopeName scopes;
  in stack ? serviceRegistry && builtins.hasAttr serviceName stack.serviceRegistry.services;
  matchesSelector = scopeName: let
    metadata = builtins.getAttr scopeName catalog;
  in if requestedScope != null
     then scopeName == requestedScope
     else requestedStack == null || metadata.stack == requestedStack;
  candidates = builtins.filter
    (scopeName: matchesSelector scopeName && declaresService scopeName)
    (builtins.attrNames scopes);
  placementFor = scopeName: let
    stack = builtins.getAttr scopeName scopes;
    metadata = builtins.getAttr scopeName catalog;
    registry = stack.serviceRegistry;
    spec = registry.serviceFor serviceName;
    group = registry.placementForService serviceName;
    endpoint = registry.endpointForGroup spec.role group;
  in {{
    scope = scopeName;
    inherit (metadata) owner placement stack;
    default = defaultSelection != null && scopeName == defaultSelection.scope;
    stable = builtins.hasAttr serviceName (stablePlacements.${{scopeName}} or {{}});
    env = stack.env or null;
    address = endpoint.address;
  }};
in map placementFor candidates"#
    );
    let value = Nix::new(nix_program.to_path_buf())?.eval_installable_apply_json(
        repository.root(),
        ".#hostManager",
        &expression,
    )?;
    let placements: Vec<ServicePlacement> =
        serde_json::from_value(value).context("decode service placement from stack registry")?;
    let placement = select_service_placement(stack, scope, service, placements)?;
    let host = inventory.host_name_for_address(&placement.address)?;
    let resource = resolve_service_resource(repository, nix_program, host, service)?;
    Ok(ResolvedLogicalService {
        scope: placement.scope,
        stack: placement.stack,
        repository_owner: placement.owner,
        stable: placement.stable,
        host: host.to_owned(),
        resource,
    })
}

fn select_service_placement(
    requested_stack: Option<&str>,
    requested_scope: Option<&str>,
    service: &str,
    mut placements: Vec<ServicePlacement>,
) -> Result<ServicePlacement> {
    if let Some(scope) = requested_scope {
        return match placements.as_slice() {
            [] => bail!("scope {scope:?} does not declare service {service:?}"),
            [_] => Ok(placements.remove(0)),
            _ => bail!("scope {scope:?} produced multiple placements for service {service:?}"),
        };
    }
    let stable = placements
        .iter()
        .enumerate()
        .filter_map(|(index, placement)| placement.stable.then_some(index))
        .collect::<Vec<_>>();
    if let [index] = stable.as_slice() {
        return Ok(placements.remove(*index));
    }
    if stable.len() > 1 {
        return ambiguous_service_placement(requested_stack, service, &placements, "stable");
    }
    let defaults = placements
        .iter()
        .enumerate()
        .filter_map(|(index, placement)| placement.default_scope.then_some(index))
        .collect::<Vec<_>>();
    if let [index] = defaults.as_slice() {
        return Ok(placements.remove(*index));
    }
    if defaults.len() > 1 {
        return ambiguous_service_placement(requested_stack, service, &placements, "default");
    }
    placements.retain(|placement| placement.placement.is_none());
    if placements.len() == 1 {
        return Ok(placements.remove(0));
    }
    if placements.is_empty() {
        match requested_stack {
            Some(stack) => bail!("stack {stack:?} does not declare service {service:?}"),
            None => bail!("no repository stack declares service {service:?}"),
        }
    }
    ambiguous_service_placement(requested_stack, service, &placements, "canonical")
}

fn ambiguous_service_placement(
    requested_stack: Option<&str>,
    service: &str,
    placements: &[ServicePlacement],
    kind: &str,
) -> Result<ServicePlacement> {
    let candidates = placements
        .iter()
        .map(|placement| {
            format!(
                "{} ({})",
                placement.scope,
                placement.env.as_deref().unwrap_or("unknown environment")
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    match requested_stack {
        Some(stack) => bail!(
            "stack {stack:?} has no unique {kind} scope for service {service:?}; candidates: {candidates}; pass --scope to select explicitly"
        ),
        None => bail!(
            "service {service:?} has no unique {kind} scope; candidates: {candidates}; pass --stack or --scope to select explicitly"
        ),
    }
}

pub fn resolve_service_resource(
    repository: &Repository,
    nix_program: &Path,
    host: &str,
    service: &str,
) -> Result<String> {
    validate_registry_name("host", host)?;
    validate_registry_name("service", service)?;
    let service = serde_json::to_string(service).context("encode service name for Nix")?;
    let expression = format!(
        r#"services: let
  logical = {service};
  names = builtins.attrNames services;
  matches = builtins.filter (name:
    name == logical || builtins.match ".*[-:]${{logical}}" name != null
  ) names;
in if builtins.length matches == 1
   then builtins.head matches
   else throw "logical service does not resolve to exactly one host-agent resource""#
    );
    let installable =
        format!(".#nixosConfigurations.{host}.config.services.abird-host-agent.services");
    let value = Nix::new(nix_program.to_path_buf())?.eval_installable_apply_json(
        repository.root(),
        &installable,
        &expression,
    )?;
    let name = value
        .as_str()
        .context("logical service resource evaluation did not return a string")?;
    Ok(format!("service:{name}"))
}

fn validate_registry_name(kind: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("{kind} name {value:?} contains unsupported characters");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placement(scope: &str, stack: &str, env: Option<&str>) -> ServicePlacement {
        ServicePlacement {
            scope: scope.to_owned(),
            stack: stack.to_owned(),
            owner: stack.to_owned(),
            placement: (scope != stack).then(|| scope.to_owned()),
            default_scope: false,
            stable: false,
            env: env.map(str::to_owned),
            address: format!("{scope}.example.test"),
        }
    }

    #[test]
    fn registry_names_are_deliberately_narrow() {
        assert!(validate_registry_name("service", "zulip-main_2").is_ok());
        assert!(validate_registry_name("service", "zulip; builtins.abort").is_err());
        assert!(validate_registry_name("service", "-zulip").is_err());
        assert!(validate_registry_name("service", &"z".repeat(65)).is_err());
        assert!(validate_registry_name("service", "").is_err());
    }

    #[test]
    fn repository_service_selection_accepts_only_one_unambiguous_canonical_scope() {
        let unique = select_service_placement(
            None,
            None,
            "chat",
            vec![placement("demo-dev", "demo-dev", Some("dev"))],
        )
        .unwrap();
        assert_eq!(unique.stack, "demo-dev");

        let ambiguous = select_service_placement(
            None,
            None,
            "chat",
            vec![
                placement("demo", "demo", Some("prod")),
                placement("demo-dev", "demo-dev", Some("dev")),
            ],
        )
        .unwrap_err()
        .to_string();
        assert!(ambiguous.contains("demo (prod)"));
        assert!(ambiguous.contains("demo-dev (dev)"));
    }

    #[test]
    fn repository_service_selection_is_explicit_or_fails_closed() {
        let explicit = select_service_placement(
            Some("demo-dev"),
            None,
            "chat",
            vec![placement("demo-dev", "demo-dev", Some("dev"))],
        )
        .unwrap();
        assert_eq!(explicit.stack, "demo-dev");

        let ambiguous = select_service_placement(
            None,
            None,
            "chat",
            vec![
                placement("alpha", "alpha", Some("prod")),
                placement("beta", "beta", Some("prod")),
            ],
        )
        .unwrap_err()
        .to_string();
        assert!(ambiguous.contains("alpha (prod)"));
        assert!(ambiguous.contains("beta (prod)"));
        assert!(ambiguous.contains("pass --stack or --scope"));

        assert!(
            select_service_placement(Some("missing"), None, "chat", Vec::new())
                .unwrap_err()
                .to_string()
                .contains("does not declare service")
        );
    }

    #[test]
    fn repository_service_selection_prefers_stable_scope_over_canonical_stack() {
        let mut stable = placement("demo-edge", "demo", Some("prod"));
        stable.stable = true;
        let selected = select_service_placement(
            None,
            None,
            "chat",
            vec![placement("demo", "demo", Some("prod")), stable],
        )
        .unwrap();
        assert_eq!(selected.scope, "demo-edge");
    }

    #[test]
    fn repository_service_selection_uses_explicit_default_scope() {
        let mut default = placement("demo", "demo", Some("prod"));
        default.default_scope = true;
        let selected = select_service_placement(
            None,
            None,
            "chat",
            vec![default, placement("demo-dev", "demo-dev", Some("dev"))],
        )
        .unwrap();
        assert_eq!(selected.scope, "demo");

        let mut stable = placement("demo-edge", "demo", Some("prod"));
        stable.stable = true;
        let mut default = placement("demo", "demo", Some("prod"));
        default.default_scope = true;
        let selected = select_service_placement(None, None, "chat", vec![default, stable]).unwrap();
        assert_eq!(selected.scope, "demo-edge");
    }
}
