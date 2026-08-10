use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::agent_adapter::HostManagerConfig;
use crate::programs::nix::Nix;
use crate::repository::Repository;

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct ServicePlacement {
    stack: String,
    env: Option<String>,
    address: String,
    group: String,
    role: String,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ResolvedLogicalService {
    pub host: String,
    pub resource: String,
}

pub fn resolve_service_host(
    repository: &Repository,
    nix_program: &Path,
    inventory: &HostManagerConfig,
    stack: Option<&str>,
    service: &str,
) -> Result<ResolvedLogicalService> {
    if let Some(stack) = stack {
        validate_registry_name("stack", stack)?;
    }
    validate_registry_name("service", service)?;
    let stack_literal = serde_json::to_string(&stack).context("encode stack name for Nix")?;
    let service_literal = serde_json::to_string(service).context("encode service name for Nix")?;
    let expression = format!(
        r#"stacks: let
  requestedStack = {stack_literal};
  serviceName = {service_literal};
  concreteStacks = builtins.removeAttrs stacks ["all"];
  declaresService = stackName: let
    stack = builtins.getAttr stackName concreteStacks;
  in stack ? serviceRegistry && builtins.hasAttr serviceName stack.serviceRegistry.services;
  candidates =
    if requestedStack == null
    then builtins.filter declaresService (builtins.attrNames concreteStacks)
    else if builtins.hasAttr requestedStack concreteStacks && declaresService requestedStack
    then [requestedStack]
    else [];
  placementFor = stackName: let
    stack = builtins.getAttr stackName concreteStacks;
    registry = stack.serviceRegistry;
    spec = registry.serviceFor serviceName;
    group = registry.placementForService serviceName;
    endpoint = registry.endpointForGroup spec.role group;
  in {{
    env = stack.env or null;
    stack = stackName;
    address = endpoint.address;
    inherit group;
    role = spec.role;
  }};
in map placementFor candidates"#
    );
    let value = Nix::new(nix_program.to_path_buf())?.eval_file_apply_json(
        &repository.root().join("lib/stacks/default.nix"),
        &expression,
    )?;
    let placements: Vec<ServicePlacement> =
        serde_json::from_value(value).context("decode service placement from stack registry")?;
    let placement = select_service_placement(stack, service, placements)?;
    let host = inventory.host_name_for_address(&placement.address)?;
    let resource = resolve_service_resource(repository, nix_program, host, service)?;
    Ok(ResolvedLogicalService {
        host: host.to_owned(),
        resource,
    })
}

fn select_service_placement(
    requested_stack: Option<&str>,
    service: &str,
    mut placements: Vec<ServicePlacement>,
) -> Result<ServicePlacement> {
    if let Some(stack) = requested_stack {
        return match placements.as_slice() {
            [] => bail!("stack {stack:?} does not declare service {service:?}"),
            [_] => Ok(placements.remove(0)),
            _ => bail!("stack {stack:?} produced multiple placements for service {service:?}"),
        };
    }
    if placements.len() == 1 {
        return Ok(placements.remove(0));
    }
    let production = placements
        .iter()
        .enumerate()
        .filter_map(|(index, placement)| {
            (placement.env.as_deref() == Some("prod")).then_some(index)
        })
        .collect::<Vec<_>>();
    if let [index] = production.as_slice() {
        return Ok(placements.remove(*index));
    }
    if placements.is_empty() {
        bail!("no repository stack declares service {service:?}");
    }
    let candidates = placements
        .iter()
        .map(|placement| {
            format!(
                "{} ({})",
                placement.stack,
                placement.env.as_deref().unwrap_or("unknown environment")
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    bail!(
        "service {service:?} has no unique production stack; candidates: {candidates}; pass --stack to select explicitly"
    )
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

    fn placement(stack: &str, env: Option<&str>) -> ServicePlacement {
        ServicePlacement {
            stack: stack.to_owned(),
            env: env.map(str::to_owned),
            address: format!("{stack}.example.test"),
            group: "default".to_owned(),
            role: "app".to_owned(),
        }
    }

    #[test]
    fn registry_names_are_deliberately_narrow() {
        assert!(validate_registry_name("service", "zulip-main_2").is_ok());
        assert!(validate_registry_name("service", "zulip; builtins.abort").is_err());
        assert!(validate_registry_name("service", "").is_err());
    }

    #[test]
    fn repository_service_selection_prefers_unique_then_production() {
        let unique =
            select_service_placement(None, "chat", vec![placement("demo-dev", Some("dev"))])
                .unwrap();
        assert_eq!(unique.stack, "demo-dev");

        let production = select_service_placement(
            None,
            "chat",
            vec![
                placement("demo", Some("prod")),
                placement("demo-dev", Some("dev")),
            ],
        )
        .unwrap();
        assert_eq!(production.stack, "demo");
    }

    #[test]
    fn repository_service_selection_is_explicit_or_fails_closed() {
        let explicit = select_service_placement(
            Some("demo-dev"),
            "chat",
            vec![placement("demo-dev", Some("dev"))],
        )
        .unwrap();
        assert_eq!(explicit.stack, "demo-dev");

        let ambiguous = select_service_placement(
            None,
            "chat",
            vec![
                placement("alpha", Some("prod")),
                placement("beta", Some("prod")),
            ],
        )
        .unwrap_err()
        .to_string();
        assert!(ambiguous.contains("alpha (prod)"));
        assert!(ambiguous.contains("beta (prod)"));
        assert!(ambiguous.contains("pass --stack"));

        assert!(
            select_service_placement(Some("missing"), "chat", Vec::new())
                .unwrap_err()
                .to_string()
                .contains("does not declare service")
        );
    }
}
