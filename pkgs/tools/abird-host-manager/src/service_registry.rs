use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::agent_adapter::HostManagerConfig;
use crate::programs::nix::Nix;
use crate::repository::Repository;

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct ServicePlacement {
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
    stack: &str,
    service: &str,
) -> Result<ResolvedLogicalService> {
    validate_registry_name("stack", stack)?;
    validate_registry_name("service", service)?;
    let stack_literal = serde_json::to_string(stack).context("encode stack name for Nix")?;
    let service_literal = serde_json::to_string(service).context("encode service name for Nix")?;
    let expression = format!(
        r#"stacks: let
  stackName = {stack_literal};
  serviceName = {service_literal};
  stack = if builtins.hasAttr stackName stacks then builtins.getAttr stackName stacks else throw "unknown stack";
  registry = stack.serviceRegistry;
  spec = registry.serviceFor serviceName;
  group = registry.placementForService serviceName;
  endpoint = registry.endpointForGroup spec.role group;
in {{ address = endpoint.address; inherit group; role = spec.role; }}"#
    );
    let value = Nix::new(nix_program.to_path_buf())?.eval_file_apply_json(
        &repository.root().join("lib/stacks/default.nix"),
        &expression,
    )?;
    let placement: ServicePlacement =
        serde_json::from_value(value).context("decode service placement from stack registry")?;
    let host = inventory.host_name_for_address(&placement.address)?;
    let resource = resolve_service_resource(repository, nix_program, host, service)?;
    Ok(ResolvedLogicalService {
        host: host.to_owned(),
        resource,
    })
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

    #[test]
    fn registry_names_are_deliberately_narrow() {
        assert!(validate_registry_name("service", "zulip-main_2").is_ok());
        assert!(validate_registry_name("service", "zulip; builtins.abort").is_err());
        assert!(validate_registry_name("service", "").is_err());
    }
}
