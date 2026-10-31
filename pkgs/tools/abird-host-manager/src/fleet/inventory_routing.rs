//! Process-local named-route selection for Nixbot inventory.

use std::collections::{BTreeMap, BTreeSet};
use std::net::IpAddr;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Number, Value};

use super::system_identity;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RouteRequest {
    #[default]
    Auto,
    Default,
    Cf,
    Ts,
}

impl RouteRequest {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Default => "default",
            Self::Cf => "cf",
            Self::Ts => "ts",
        }
    }

    pub(crate) fn parse(value: &str) -> Result<Self> {
        match value {
            "auto" => Ok(Self::Auto),
            "default" => Ok(Self::Default),
            "cf" => Ok(Self::Cf),
            "ts" => Ok(Self::Ts),
            _ => bail!("unsupported route: {value} (expected auto|default|cf|ts)"),
        }
    }

    fn named(self) -> Option<RouteName> {
        match self {
            Self::Cf => Some(RouteName::Cf),
            Self::Ts => Some(RouteName::Ts),
            Self::Auto | Self::Default => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RouteName {
    Default,
    Cf,
    Ts,
}

impl RouteName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Cf => "cf",
            Self::Ts => "ts",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RouteSource {
    ManagedSelf,
    Developer,
    Override,
    Cli,
    Env,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteDecision {
    pub request: RouteRequest,
    pub selected: RouteName,
    pub source: RouteSource,
    #[serde(rename = "self", default, skip_serializing_if = "Option::is_none")]
    pub self_host: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteHopResolution {
    pub host: String,
    pub selected: RouteName,
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default)]
    pub proxy_command: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostRouteResolution {
    pub requested: RouteRequest,
    pub active: RouteName,
    pub selected: RouteName,
    #[serde(default)]
    pub fallback: bool,
    #[serde(default)]
    pub effective: bool,
    pub source: RouteSource,
    #[serde(rename = "self", default, skip_serializing_if = "Option::is_none")]
    pub self_host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub route_hop: Option<String>,
    #[serde(default)]
    pub proxy_command: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hops: Vec<RouteHopResolution>,
}

#[derive(Clone, Debug, Default)]
pub struct SelfIdentity {
    aliases: BTreeSet<String>,
    managed: bool,
}

impl SelfIdentity {
    pub fn detect() -> Result<Self> {
        let managed = managed_execution_context()?;
        let aliases = if managed {
            system_identity::local_kernel_host_aliases()
                .into_iter()
                .flat_map(|alias| normalized_aliases(&alias))
                .collect::<BTreeSet<_>>()
        } else {
            BTreeSet::new()
        };
        if managed && aliases.is_empty() {
            bail!("could not determine the local managed host identity");
        }
        Ok(Self { aliases, managed })
    }

    #[cfg(test)]
    fn from_aliases(aliases: impl IntoIterator<Item = &'static str>) -> Self {
        Self {
            aliases: aliases.into_iter().flat_map(normalized_aliases).collect(),
            managed: true,
        }
    }

    #[cfg(test)]
    fn developer_from_aliases(aliases: impl IntoIterator<Item = &'static str>) -> Self {
        Self {
            aliases: aliases.into_iter().flat_map(normalized_aliases).collect(),
            managed: false,
        }
    }

    pub fn is_managed(&self) -> bool {
        self.managed
    }

    fn matches(&self, value: &str) -> bool {
        normalized_aliases(value)
            .into_iter()
            .any(|alias| self.aliases.contains(&alias))
    }
}

pub(crate) fn managed_execution_context() -> Result<bool> {
    match std::env::var("NIXBOT_EXECUTOR_KIND") {
        Ok(value) if value == "managed" => return Ok(true),
        Ok(value) if value == "developer" => return Ok(false),
        Ok(value) if value.is_empty() => {}
        Ok(value) => bail!("unsupported NIXBOT_EXECUTOR_KIND: {value}"),
        Err(std::env::VarError::NotUnicode(_)) => {
            bail!("NIXBOT_EXECUTOR_KIND must be valid UTF-8")
        }
        Err(std::env::VarError::NotPresent) => {}
    }
    Ok(std::env::var_os("SSH_ORIGINAL_COMMAND").is_some()
        || std::env::var_os("ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION")
            .is_some_and(|value| value == "1"))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RouteSpec {
    target: String,
    port: Option<u16>,
    proxy_jump: Option<String>,
    proxy_command: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct HostRoutes {
    default: RouteSpec,
    named: BTreeMap<String, RouteSpec>,
}

/// Validate, select, and flatten named routes into the transport fields used by
/// the rest of the manager.
pub fn apply_named_routes(
    inventory: &mut Value,
    base: &Value,
    override_layer: Option<&Value>,
    request: RouteRequest,
    identity: Option<&SelfIdentity>,
) -> Result<RouteDecision> {
    apply_named_routes_with_source(
        inventory,
        base,
        override_layer,
        request,
        RouteSource::Cli,
        identity,
    )
}

pub fn apply_named_routes_with_source(
    inventory: &mut Value,
    base: &Value,
    override_layer: Option<&Value>,
    request: RouteRequest,
    explicit_source: RouteSource,
    identity: Option<&SelfIdentity>,
) -> Result<RouteDecision> {
    normalize_host_map(inventory)?;
    validate_process_route_controls(inventory, "merged inventory", true)?;
    validate_process_route_controls(base, "tracked inventory", false)?;
    let base_routes = parse_inventory_routes(base)?;
    validate_route_graphs(&base_routes)?;
    if override_layer.is_some() && identity.is_some_and(SelfIdentity::is_managed) {
        bail!("Nixbot config overrides are allowed only for direct developer execution");
    }
    let override_request = match override_layer {
        Some(layer) => {
            validate_process_route_controls(layer, "operator override", true)?;
            config_route_request(layer)?
        }
        None => None,
    };

    let routes = parse_inventory_routes(inventory)?;
    validate_route_graphs(&routes)?;
    let decision =
        resolve_route_decision(base, request, override_request, explicit_source, identity)?;
    if let Some(route) = decision.request.named()
        && !routes
            .values()
            .any(|host| host.named.contains_key(route.as_str()))
    {
        bail!(
            "explicit route {} does not select that route on any host path",
            route.as_str()
        );
    }
    rewrite_inventory(inventory, &routes, &decision)?;
    Ok(decision)
}

pub fn validate_named_routes(
    inventory: &Value,
    base: &Value,
    override_layer: Option<&Value>,
) -> Result<()> {
    let mut inventory = inventory.clone();
    normalize_host_map(&mut inventory)?;
    validate_process_route_controls(&inventory, "merged inventory", true)?;
    validate_process_route_controls(base, "tracked inventory", false)?;
    let base_routes = parse_inventory_routes(base)?;
    validate_route_graphs(&base_routes)?;
    if let Some(layer) = override_layer {
        validate_process_route_controls(layer, "operator override", true)?;
        config_route_request(layer)?;
    }
    let routes = parse_inventory_routes(&inventory)?;
    validate_route_graphs(&routes)
}

pub fn route_request_from_env() -> Result<RouteRequest> {
    match std::env::var("NIXBOT_ROUTE") {
        Ok(value) if value.is_empty() => Ok(RouteRequest::Auto),
        Ok(value) => RouteRequest::parse(&value),
        Err(std::env::VarError::NotPresent) => Ok(RouteRequest::Auto),
        Err(std::env::VarError::NotUnicode(_)) => bail!("NIXBOT_ROUTE must be valid UTF-8"),
    }
}

pub fn route_line(
    host: &str,
    target: Option<&str>,
    port: Option<u16>,
    route: Option<&HostRouteResolution>,
) -> Option<String> {
    let route = route?;
    let selected = if route.fallback {
        format!("{}→{}", route.active.as_str(), route.selected.as_str())
    } else {
        route.selected.as_str().to_owned()
    };
    let port = port.map_or_else(String::new, |port| format!(":{port}"));
    let through = if route.hops.is_empty() {
        String::new()
    } else {
        format!(
            " through {}",
            route
                .hops
                .iter()
                .map(|hop| format!("{}({})", hop.host, hop.selected.as_str()))
                .collect::<Vec<_>>()
                .join(" → ")
        )
    };
    let proxy = if route.proxy_command || route.hops.iter().any(|hop| hop.proxy_command) {
        " + proxy-command"
    } else {
        ""
    };
    let provenance = match route.source {
        RouteSource::Cli => "--route".to_owned(),
        RouteSource::Env => "NIXBOT_ROUTE".to_owned(),
        RouteSource::ManagedSelf => route
            .self_host
            .as_deref()
            .map_or_else(|| "managed self".to_owned(), |name| format!("self={name}")),
        RouteSource::Developer => "developer".to_owned(),
        RouteSource::Override => "override".to_owned(),
    };
    Some(format!(
        "  route: {selected} via {}{port}{through}{proxy} ({provenance})",
        target.unwrap_or(host)
    ))
}

fn normalize_host_map(inventory: &mut Value) -> Result<()> {
    if !inventory.is_object() {
        bail!("inventory must be an attrset");
    }
    match inventory.get("hosts") {
        None | Some(Value::Object(_)) => {}
        Some(_) => bail!("inventory hosts must be an attrset"),
    }
    match inventory.get("config") {
        None | Some(Value::Object(_)) => Ok(()),
        Some(_) => bail!("inventory config must be an attrset"),
    }
}

fn validate_process_route_controls(
    layer: &Value,
    label: &str,
    allow_config_route: bool,
) -> Result<()> {
    let layer = layer
        .as_object()
        .with_context(|| format!("{label} inventory must be an attrset"))?;
    let config = match layer.get("config") {
        None => None,
        Some(Value::Object(config)) => Some(config),
        Some(_) => bail!("{label} config must be an attrset"),
    };
    if !allow_config_route && config.is_some_and(|config| config.contains_key("route")) {
        bail!("tracked config.route is forbidden; put config.route in the local override");
    }
    if let Some(config) = config {
        match config.get("hostDefaults") {
            None | Some(Value::Object(_)) => {}
            Some(_) => bail!("{label} config.hostDefaults must be an attrset"),
        }
    }
    let Some(hosts) = layer.get("hosts") else {
        return Ok(());
    };
    let Some(hosts) = hosts.as_object() else {
        bail!("{label} hosts must be an attrset");
    };
    for (name, host) in hosts {
        let Some(host) = host.as_object() else {
            bail!("{label} host {name} must be an attrset");
        };
        match host.get("nixbotConfig") {
            None | Some(Value::Null) => {}
            Some(Value::Object(config)) => {
                if config.contains_key("route") {
                    bail!(
                        "host {name}: nixbotConfig.route is unsupported; routes are process-local"
                    );
                }
            }
            Some(_) => bail!("{label} host {name}.nixbotConfig must be an attrset"),
        }
        parse_host_routes(name, &Value::Object(host.clone()))?;
    }
    Ok(())
}

fn config_route_request(layer: &Value) -> Result<Option<RouteRequest>> {
    match layer.pointer("/config/route") {
        None => Ok(None),
        Some(Value::String(value)) => RouteRequest::parse(value).map(Some),
        Some(_) => bail!("override config.route must be auto, default, cf, or ts"),
    }
}

fn parse_inventory_routes(inventory: &Value) -> Result<BTreeMap<String, HostRoutes>> {
    let Some(hosts) = inventory.get("hosts") else {
        return Ok(BTreeMap::new());
    };
    let hosts = hosts
        .as_object()
        .context("inventory hosts must be an attrset")?;
    hosts
        .iter()
        .map(|(name, host)| parse_host_routes(name, host).map(|routes| (name.clone(), routes)))
        .collect()
}

fn parse_host_routes(name: &str, host: &Value) -> Result<HostRoutes> {
    let host = host
        .as_object()
        .with_context(|| format!("host {name} must be an attrset"))?;
    if host.contains_key("route") || host.contains_key("routing") {
        bail!("host {name}: inventory already contains normalized route state");
    }
    match host.get("nixbotConfig") {
        None | Some(Value::Null) => {}
        Some(Value::Object(config)) => {
            if config.contains_key("route") {
                bail!("host {name}: nixbotConfig.route is unsupported; routes are process-local");
            }
        }
        Some(_) => bail!("host {name}: nixbotConfig must be an attrset"),
    }
    match host.get("resourceId") {
        None | Some(Value::Null) => {}
        Some(Value::String(value)) if !value.is_empty() => {}
        Some(Value::String(_)) => bail!("host {name}: resourceId must be non-empty"),
        Some(_) => bail!("host {name}: resourceId must be a string"),
    }
    match host.get("groups") {
        None => {}
        Some(Value::Array(groups))
            if groups
                .iter()
                .all(|group| group.as_str().is_some_and(|group| !group.is_empty())) => {}
        Some(Value::Array(_)) => bail!("host {name}: groups must contain non-empty strings"),
        Some(_) => bail!("host {name}: groups must be a list"),
    }

    let default = parse_route(name, "default", host, false)?;
    let named = match host.get("routes") {
        None => BTreeMap::new(),
        Some(Value::Object(routes)) => routes
            .iter()
            .map(|(route_name, route)| {
                if route_name == "default" {
                    bail!("host {name}: routes.default is implicit and must not be declared");
                }
                if !matches!(route_name.as_str(), "cf" | "ts") {
                    bail!("host {name}: unsupported route {route_name}; expected cf or ts");
                }
                parse_named_route(name, route_name, route).map(|route| (route_name.clone(), route))
            })
            .collect::<Result<_>>()?,
        Some(_) => bail!("host {name}: routes must be an attrset"),
    };
    Ok(HostRoutes { default, named })
}

fn parse_named_route(host_name: &str, route_name: &str, route: &Value) -> Result<RouteSpec> {
    match route {
        Value::String(target) if !target.is_empty() => Ok(RouteSpec {
            target: target.clone(),
            port: None,
            proxy_jump: None,
            proxy_command: None,
        }),
        Value::String(_) => {
            bail!("host {host_name}: route {route_name} must be a non-empty string")
        }
        Value::Object(route) => parse_route(host_name, route_name, route, true),
        _ => bail!("host {host_name}: route {route_name} must be a string or attrset"),
    }
}

fn parse_route(
    host_name: &str,
    route_name: &str,
    route: &Map<String, Value>,
    explicit: bool,
) -> Result<RouteSpec> {
    if explicit {
        for key in route.keys() {
            if !matches!(
                key.as_str(),
                "target" | "port" | "proxyJump" | "proxyCommand"
            ) {
                bail!("host {host_name}: route {route_name} has unknown field {key}");
            }
        }
    }
    let target = string_field(route, "target", host_name, route_name, explicit)?
        .unwrap_or_else(|| host_name.to_owned());
    let port = port_field(route, "port", host_name, route_name)?;
    let proxy_jump = string_field(route, "proxyJump", host_name, route_name, false)?;
    let proxy_command = string_field(route, "proxyCommand", host_name, route_name, false)?;
    if proxy_jump.is_some() && proxy_command.is_some() {
        bail!("host {host_name}: route {route_name} cannot define both proxyJump and proxyCommand");
    }
    Ok(RouteSpec {
        target,
        port,
        proxy_jump,
        proxy_command,
    })
}

fn string_field(
    route: &Map<String, Value>,
    key: &str,
    host: &str,
    route_name: &str,
    required: bool,
) -> Result<Option<String>> {
    match route.get(key) {
        None | Some(Value::Null) => {
            if required {
                bail!("host {host}: route {route_name} requires non-empty target");
            }
            Ok(None)
        }
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => {
            bail!("host {host}: route {route_name} {key} must be a non-empty string")
        }
        Some(_) => bail!("host {host}: route {route_name} {key} must be a string"),
    }
}

fn port_field(
    route: &Map<String, Value>,
    key: &str,
    host: &str,
    route_name: &str,
) -> Result<Option<u16>> {
    match route.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port != 0)
            .map(Some)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "host {host}: route {route_name} port must be an integer from 1 to 65535"
                )
            }),
        Some(Value::String(value)) if value.bytes().all(|byte| byte.is_ascii_digit()) => value
            .parse::<u16>()
            .ok()
            .filter(|port| *port != 0)
            .map(Some)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "host {host}: route {route_name} port must be an integer from 1 to 65535"
                )
            }),
        Some(_) => bail!("host {host}: route {route_name} port must be an integer"),
    }
}

fn validate_route_graphs(hosts: &BTreeMap<String, HostRoutes>) -> Result<()> {
    let mut names = BTreeSet::from(["default".to_owned(), "cf".to_owned(), "ts".to_owned()]);
    names.extend(hosts.values().flat_map(|host| host.named.keys().cloned()));
    for requested in names {
        for host in hosts.keys() {
            validate_route_chain(hosts, host, &requested)?;
        }
    }
    Ok(())
}

fn validate_route_chain(
    hosts: &BTreeMap<String, HostRoutes>,
    start: &str,
    requested: &str,
) -> Result<()> {
    let mut chain = Vec::new();
    let mut current = start;
    loop {
        if let Some(cycle_start) = chain.iter().position(|host| host == current) {
            let mut cycle = chain[cycle_start..].to_vec();
            cycle.push(current.to_owned());
            bail!("route {requested} cycle detected: {}", cycle.join(" -> "));
        }
        chain.push(current.to_owned());
        let host = &hosts[current];
        let (route, selected) = select_route(host, requested);
        let Some(next) = route.proxy_jump.as_deref() else {
            return Ok(());
        };
        if !hosts.contains_key(next) {
            bail!("host {current}: route {selected} proxyJump names unknown host {next}");
        }
        current = next;
    }
}

fn resolve_route_decision(
    base: &Value,
    request: RouteRequest,
    override_request: Option<RouteRequest>,
    explicit_source: RouteSource,
    identity: Option<&SelfIdentity>,
) -> Result<RouteDecision> {
    if override_request.is_some() && identity.is_some_and(|identity| identity.managed) {
        bail!("override config.route is allowed only for direct developer execution");
    }
    match request {
        RouteRequest::Default => Ok(RouteDecision {
            request,
            selected: RouteName::Default,
            source: explicit_source,
            self_host: None,
        }),
        RouteRequest::Cf | RouteRequest::Ts => Ok(RouteDecision {
            request,
            selected: request.named().expect("named route request"),
            source: explicit_source,
            self_host: None,
        }),
        RouteRequest::Auto => {
            if let Some(override_request) =
                override_request.filter(|route| *route != RouteRequest::Auto)
            {
                return Ok(RouteDecision {
                    request,
                    selected: override_request.named().unwrap_or(RouteName::Default),
                    source: RouteSource::Override,
                    self_host: None,
                });
            }
            let identity = identity.context("auto route selection requires local identity")?;
            if !identity.managed {
                return Ok(RouteDecision {
                    request,
                    selected: RouteName::Cf,
                    source: RouteSource::Developer,
                    self_host: None,
                });
            }
            let self_host = resolve_managed_self(base, identity)?.context(
                "managed executor does not match any tracked host by exact host/resource identity; pass an explicit --route",
            )?;
            Ok(RouteDecision {
                request,
                selected: RouteName::Default,
                source: RouteSource::ManagedSelf,
                self_host: Some(self_host),
            })
        }
    }
}

fn resolve_managed_self(base: &Value, identity: &SelfIdentity) -> Result<Option<String>> {
    let Some(hosts) = base.get("hosts") else {
        return Ok(None);
    };
    if hosts.is_null() {
        return Ok(None);
    }
    let hosts = hosts
        .as_object()
        .context("tracked inventory hosts must be an attrset")?;
    let mut key_matches = Vec::new();
    let mut resource_matches = Vec::new();
    for (name, host) in hosts {
        let host = host
            .as_object()
            .with_context(|| format!("tracked host {name} must be an attrset"))?;
        let resource = match host.get("resourceId") {
            None | Some(Value::Null) => None,
            Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            Some(Value::String(_)) => bail!("host {name}: resourceId must be non-empty"),
            Some(_) => bail!("host {name}: resourceId must be a string"),
        };
        if managed_identity_matches(identity, name) {
            key_matches.push(name.clone());
        }
        if resource.is_some_and(|resource| managed_identity_matches(identity, resource)) {
            resource_matches.push(name.clone());
        }
    }
    let matching = if key_matches.is_empty() {
        resource_matches
    } else {
        key_matches
    };
    match matching.as_slice() {
        [] => Ok(None),
        [name] => Ok(Some(name.clone())),
        _ => bail!(
            "managed executor identity is ambiguous: {}; pass an explicit --route",
            matching.join(", ")
        ),
    }
}

fn rewrite_inventory(
    inventory: &mut Value,
    routes: &BTreeMap<String, HostRoutes>,
    decision: &RouteDecision,
) -> Result<()> {
    let Some(hosts) = inventory.get_mut("hosts").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    let requested = decision.selected.as_str();
    for (name, host) in hosts.iter_mut() {
        let host = host
            .as_object_mut()
            .with_context(|| format!("host {name} must be an attrset"))?;
        let (selected_route, selected_name) = select_route(&routes[name], requested);
        host.insert(
            "target".to_owned(),
            Value::String(selected_route.target.clone()),
        );
        set_or_remove_port(host, selected_route.port);
        set_or_remove_string(host, "proxyJump", selected_route.proxy_jump.clone());
        set_or_remove_string(host, "proxyCommand", selected_route.proxy_command.clone());
        host.remove("routes");
        let selected = route_name(selected_name);
        let hops = route_hops(routes, name, requested);
        let route_hop = if decision.selected == RouteName::Default {
            None
        } else if selected == decision.selected {
            Some(name.clone())
        } else {
            hops.iter()
                .find(|hop| hop.selected == decision.selected)
                .map(|hop| hop.host.clone())
        };
        host.insert(
            "routing".to_owned(),
            serde_json::to_value(HostRouteResolution {
                requested: decision.request,
                active: decision.selected,
                selected,
                fallback: selected_name != requested,
                effective: decision.selected == RouteName::Default || route_hop.is_some(),
                source: decision.source,
                self_host: decision.self_host.clone(),
                route_hop,
                proxy_command: selected_route.proxy_command.is_some(),
                hops,
            })?,
        );
    }
    Ok(())
}

fn route_hops(
    hosts: &BTreeMap<String, HostRoutes>,
    start: &str,
    requested: &str,
) -> Vec<RouteHopResolution> {
    let mut hops = Vec::new();
    let (mut route, _) = select_route(&hosts[start], requested);
    while let Some(next) = route.proxy_jump.as_deref() {
        let (next_route, selected) = select_route(&hosts[next], requested);
        hops.push(RouteHopResolution {
            host: next.to_owned(),
            selected: route_name(selected),
            target: next_route.target.clone(),
            port: next_route.port,
            proxy_command: next_route.proxy_command.is_some(),
        });
        route = next_route;
    }
    hops
}

fn select_route<'a, 'b>(host: &'a HostRoutes, requested: &'b str) -> (&'a RouteSpec, &'b str) {
    if requested != "default"
        && let Some(route) = host.named.get(requested)
    {
        return (route, requested);
    }
    (&host.default, "default")
}

fn route_name(name: &str) -> RouteName {
    match name {
        "default" => RouteName::Default,
        "cf" => RouteName::Cf,
        "ts" => RouteName::Ts,
        _ => unreachable!("validated route name: {name}"),
    }
}

fn set_or_remove_string(host: &mut Map<String, Value>, key: &str, value: Option<String>) {
    match value {
        Some(value) => {
            host.insert(key.to_owned(), Value::String(value));
        }
        None => {
            host.remove(key);
        }
    }
}

fn set_or_remove_port(host: &mut Map<String, Value>, port: Option<u16>) {
    match port {
        Some(port) => {
            host.insert("port".to_owned(), Value::Number(Number::from(port)));
        }
        None => {
            host.remove("port");
        }
    }
}

fn managed_identity_matches(identity: &SelfIdentity, value: &str) -> bool {
    value.parse::<IpAddr>().is_err() && identity.matches(value)
}

fn normalized_aliases(value: &str) -> Vec<String> {
    if value.is_empty() {
        Vec::new()
    } else {
        vec![value.to_owned()]
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn inventory() -> Value {
        json!({
            "hosts": {
                "edge": {
                    "target": "10.0.0.10",
                    "port": 2222,
                    "routes": {
                        "cf": {
                            "target": "edge.example",
                            "proxyCommand": "cloudflared access ssh --hostname %h"
                        },
                        "ts": "edge"
                    }
                },
                "guest": {"target": "10.0.0.20", "proxyJump": "edge"}
            },
            "config": {}
        })
    }

    #[test]
    fn default_transport_is_the_implicit_default_route() {
        let mut value = inventory();
        let decision =
            apply_named_routes(&mut value, &json!({}), None, RouteRequest::Default, None).unwrap();
        assert_eq!(decision.selected, RouteName::Default);
        assert_eq!(value["hosts"]["edge"]["target"], "10.0.0.10");
        assert_eq!(value["hosts"]["edge"]["port"], 2222);
        assert!(value["hosts"]["edge"].get("routes").is_none());
        assert_eq!(value["hosts"]["edge"]["routing"]["selected"], "default");
    }

    #[test]
    fn cf_route_is_complete_and_each_hop_falls_back_independently() {
        let mut value = inventory();
        apply_named_routes(&mut value, &json!({}), None, RouteRequest::Cf, None).unwrap();
        assert_eq!(value["hosts"]["edge"]["target"], "edge.example");
        assert!(value["hosts"]["edge"].get("port").is_none());
        assert!(value["hosts"]["edge"].get("proxyJump").is_none());
        assert_eq!(value["hosts"]["guest"]["target"], "10.0.0.20");
        assert_eq!(value["hosts"]["guest"]["routing"]["selected"], "default");
        assert_eq!(
            value["hosts"]["guest"]["routing"]["hops"][0]["host"],
            "edge"
        );
        assert_eq!(
            value["hosts"]["guest"]["routing"]["hops"][0]["selected"],
            "cf"
        );
    }

    #[test]
    fn string_route_is_a_complete_target_only_route() {
        let mut value = inventory();
        apply_named_routes(&mut value, &json!({}), None, RouteRequest::Ts, None).unwrap();
        assert_eq!(value["hosts"]["edge"]["target"], "edge");
        assert!(value["hosts"]["edge"].get("port").is_none());
        assert!(value["hosts"]["edge"].get("proxyCommand").is_none());
        assert_eq!(value["hosts"]["guest"]["routing"]["routeHop"], "edge");
        assert_eq!(
            value["hosts"]["guest"]["routing"]["hops"][0]["selected"],
            "ts"
        );
    }

    #[test]
    fn route_specific_jump_is_selected_recursively() {
        let mut value = json!({
            "hosts": {
                "target": {
                    "target": "10.0.0.3",
                    "proxyJump": "default-gateway",
                    "routes": {"cf": {"target": "target.example", "proxyJump": "public-gateway"}}
                },
                "default-gateway": {"target": "10.0.0.1"},
                "public-gateway": {
                    "target": "10.0.0.2",
                    "routes": {"cf": {"target": "public.example", "proxyCommand": "tunnel %h"}}
                }
            }
        });
        apply_named_routes(&mut value, &json!({}), None, RouteRequest::Cf, None).unwrap();
        assert_eq!(value["hosts"]["target"]["proxyJump"], "public-gateway");
        assert_eq!(value["hosts"]["public-gateway"]["target"], "public.example");
    }

    #[test]
    fn shared_route_plans_match_the_bash_contract() {
        let fixture_text = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/named-routes.json"
        ));
        let fixture: Value = serde_json::from_str(fixture_text).unwrap();
        assert_eq!(fixture["schemaVersion"], 2);
        for case in fixture["cases"].as_array().unwrap() {
            let mut inventory = case["inventory"].clone();
            let base = inventory.clone();
            let request = RouteRequest::parse(case["request"].as_str().unwrap()).unwrap();
            apply_named_routes(&mut inventory, &base, None, request, None)
                .unwrap_or_else(|error| panic!("shared fixture {} failed: {error}", case["name"]));
            for (host, expected) in case["expected"].as_object().unwrap() {
                let actual = &inventory["hosts"][host];
                assert_eq!(
                    actual["target"], expected["target"],
                    "{} {host}",
                    case["name"]
                );
                assert_eq!(
                    actual["routing"]["selected"], expected["selected"],
                    "{} {host}",
                    case["name"]
                );
                assert_eq!(
                    actual["routing"]["fallback"], expected["fallback"],
                    "{} {host}",
                    case["name"]
                );
                for field in ["proxyJump", "proxyCommand"] {
                    if let Some(value) = expected.get(field) {
                        assert_eq!(&actual[field], value, "{} {host} {field}", case["name"]);
                    }
                }
            }
        }
    }

    #[test]
    fn validates_unknown_jumps_and_cycles_for_dormant_routes() {
        let mut unknown = json!({
            "hosts": {"a": {"routes": {"cf": {"target": "a.example", "proxyJump": "missing"}}}}
        });
        let error = apply_named_routes(&mut unknown, &json!({}), None, RouteRequest::Default, None)
            .unwrap_err()
            .to_string();
        assert!(error.contains("unknown host missing"), "{error}");

        let mut cycle = json!({
            "hosts": {
                "a": {"routes": {"cf": {"target": "a.example", "proxyJump": "b"}}},
                "b": {"routes": {"cf": {"target": "b.example", "proxyJump": "a"}}}
            }
        });
        let error = apply_named_routes(&mut cycle, &json!({}), None, RouteRequest::Default, None)
            .unwrap_err()
            .to_string();
        assert!(error.contains("a -> b -> a"), "{error}");
    }

    #[test]
    fn rejects_malformed_routes() {
        for (mut value, expected) in [
            (
                json!({"hosts": null, "config": {}}),
                "hosts must be an attrset",
            ),
            (
                json!({"hosts": {"a": {}}, "config": false}),
                "config must be an attrset",
            ),
            (
                json!({"hosts": {"a": {}}, "config": null}),
                "config must be an attrset",
            ),
            (
                json!({"hosts": {"a": {}}, "config": {"hostDefaults": false}}),
                "config.hostDefaults must be an attrset",
            ),
            (
                json!({"hosts": {"a": {}}, "config": {"hostDefaults": null}}),
                "config.hostDefaults must be an attrset",
            ),
            (
                json!({"hosts": {"a": {"resourceId": false}}}),
                "resourceId must be a string",
            ),
            (
                json!({"hosts": {"a": {"groups": false}}}),
                "groups must be a list",
            ),
            (
                json!({"hosts": {"a": {"groups": null}}}),
                "groups must be a list",
            ),
            (
                json!({"hosts": {"a": {"routes": {"default": {"target": "x"}}}}}),
                "routes.default",
            ),
            (
                json!({"hosts": {"a": {"routes": {"cf": {"target": ""}}}}}),
                "non-empty",
            ),
            (json!({"hosts": {"a": {"routes": {"ts": ""}}}}), "non-empty"),
            (
                json!({"hosts": {"a": {"routes": {"ts": false}}}}),
                "string or attrset",
            ),
            (
                json!({"hosts": {"a": {"routes": {"vpn": {"target": "x"}}}}}),
                "unsupported route vpn",
            ),
            (
                json!({"hosts": {"a": {"routes": {"cf": {"target": "x", "proxyJump": "b", "proxyCommand": "p"}}}, "b": {}}}),
                "both proxyJump and proxyCommand",
            ),
            (
                json!({"hosts": {"a": {"nixbotConfig": false}}}),
                "nixbotConfig must be an attrset",
            ),
        ] {
            let error =
                apply_named_routes(&mut value, &json!({}), None, RouteRequest::Default, None)
                    .unwrap_err()
                    .to_string();
            assert!(error.contains(expected), "{error}");
        }

        let base = json!({"hosts": {"edge": {"routes": {"cf": {}}}}});
        let mut masked = json!({
            "hosts": {"edge": {"routes": {"cf": {"target": "edge.example"}}}}
        });
        let error = apply_named_routes(
            &mut masked,
            &base,
            Some(&json!({"hosts": {"edge": {"routes": {"cf": {"target": "edge.example"}}}}})),
            RouteRequest::Cf,
            Some(&SelfIdentity::developer_from_aliases(["developer"])),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("requires non-empty target"), "{error}");
    }

    #[test]
    fn developer_override_can_select_and_customize_a_local_route() {
        let base = json!({
            "hosts": {
                "edge": {
                    "target": "10.0.0.10",
                    "routes": {"cf": {"target": "edge.example"}}
                }
            }
        });
        let override_layer = json!({
            "config": {"route": "cf"},
            "hosts": {
                "edge": {
                    "routes": {"cf": {"target": "local-tunnel.example"}}
                }
            }
        });
        let mut merged = json!({
            "config": {"route": "cf"},
            "hosts": {
                "edge": {
                    "target": "10.0.0.10",
                    "routes": {"cf": {"target": "local-tunnel.example"}}
                }
            }
        });
        let decision = apply_named_routes(
            &mut merged,
            &base,
            Some(&override_layer),
            RouteRequest::Auto,
            Some(&SelfIdentity::developer_from_aliases(["edge"])),
        )
        .unwrap();
        assert_eq!(decision.selected, RouteName::Cf);
        assert_eq!(decision.source, RouteSource::Override);
        assert_eq!(merged["hosts"]["edge"]["target"], "local-tunnel.example");

        let mut managed = json!({
            "config": {"route": "cf"},
            "hosts": {
                "edge": {
                    "target": "10.0.0.10",
                    "routes": {"cf": {"target": "local-tunnel.example"}}
                }
            }
        });
        let error = apply_named_routes(
            &mut managed,
            &base,
            Some(&override_layer),
            RouteRequest::Auto,
            Some(&SelfIdentity::from_aliases(["edge"])),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("direct developer execution"), "{error}");

        let mut credentials_only = base.clone();
        let error = apply_named_routes(
            &mut credentials_only,
            &base,
            Some(&json!({"config": {"hostDefaults": {"operatorUser": "pvl"}}})),
            RouteRequest::Default,
            Some(&SelfIdentity::from_aliases(["edge"])),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("direct developer execution"), "{error}");
    }

    #[test]
    fn auto_uses_only_tracked_managed_aliases() {
        let base = json!({
            "hosts": {
                "abird-ci": {"target": "10.0.0.11"},
                "controller-record": {"target": "10.0.0.10", "resourceId": "abird-ci"}
            }
        });
        let mut managed = inventory();
        let decision = apply_named_routes(
            &mut managed,
            &base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::from_aliases(["abird-ci"])),
        )
        .unwrap();
        assert_eq!(decision.selected, RouteName::Default);
        assert_eq!(decision.self_host.as_deref(), Some("abird-ci"));

        let mut unknown = inventory();
        let decision = apply_named_routes(
            &mut unknown,
            &base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::developer_from_aliases(["developer"])),
        )
        .unwrap();
        assert_eq!(decision.selected, RouteName::Cf);

        let mut target_only = inventory();
        let decision = apply_named_routes(
            &mut target_only,
            &base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::developer_from_aliases(["10.0.0.10"])),
        )
        .unwrap();
        assert_eq!(decision.selected, RouteName::Cf);

        let mut colliding_name = inventory();
        let decision = apply_named_routes(
            &mut colliding_name,
            &base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::developer_from_aliases(["abird-ci"])),
        )
        .unwrap();
        assert_eq!(decision.selected, RouteName::Cf);

        let fqdn_base = json!({"hosts": {"node.site-b": {}}});
        let mut unrelated_fqdn = inventory();
        let error = apply_named_routes(
            &mut unrelated_fqdn,
            &fqdn_base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::from_aliases(["node.site-a"])),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("does not match"), "{error}");
    }

    #[test]
    fn explicit_route_bypasses_ambiguous_self_detection() {
        let base = json!({
            "hosts": {
                "a": {"resourceId": "same"},
                "b": {"resourceId": "same"}
            }
        });
        let mut explicit = inventory();
        apply_named_routes(&mut explicit, &base, None, RouteRequest::Cf, None).unwrap();

        let mut ineffective = json!({"hosts": {"internal": {"target": "10.0.0.1"}}});
        let ineffective_base = ineffective.clone();
        let error = apply_named_routes(
            &mut ineffective,
            &ineffective_base,
            None,
            RouteRequest::Cf,
            None,
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("does not select that route"), "{error}");

        let mut automatic = inventory();
        let error = apply_named_routes(
            &mut automatic,
            &base,
            None,
            RouteRequest::Auto,
            Some(&SelfIdentity::from_aliases(["same"])),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("ambiguous"), "{error}");
    }

    #[test]
    fn route_line_reports_fallback_and_selected_hops() {
        let route = HostRouteResolution {
            requested: RouteRequest::Auto,
            active: RouteName::Cf,
            selected: RouteName::Default,
            fallback: true,
            effective: true,
            source: RouteSource::Developer,
            self_host: None,
            route_hop: Some("edge".to_owned()),
            proxy_command: false,
            hops: vec![RouteHopResolution {
                host: "edge".to_owned(),
                selected: RouteName::Cf,
                target: "edge.example".to_owned(),
                port: None,
                proxy_command: true,
            }],
        };
        assert_eq!(
            route_line("guest", Some("10.0.0.20"), None, Some(&route)).unwrap(),
            "  route: cf→default via 10.0.0.20 through edge(cf) + proxy-command (developer)"
        );
    }

    #[test]
    fn route_parser_is_exact() {
        for value in ["", " cf", "cf ", "on", "off", "other"] {
            assert!(RouteRequest::parse(value).is_err(), "{value:?}");
        }
        assert_eq!(RouteRequest::parse("auto").unwrap(), RouteRequest::Auto);
        assert_eq!(
            RouteRequest::parse("default").unwrap(),
            RouteRequest::Default
        );
        assert_eq!(RouteRequest::parse("cf").unwrap(), RouteRequest::Cf);
        assert_eq!(RouteRequest::parse("ts").unwrap(), RouteRequest::Ts);
    }
}
