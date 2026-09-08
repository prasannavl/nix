use std::collections::{BTreeMap, BTreeSet, VecDeque};

use anyhow::{Result, bail};

use super::inventory::{DeployMode, Inventory};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SelectionOptions {
    pub groups: Vec<String>,
    pub host: Option<String>,
    pub hosts: Option<String>,
    pub control_plane_first: bool,
    pub deploy_jobs_per_domain: usize,
}

impl Default for SelectionOptions {
    fn default() -> Self {
        Self {
            groups: Vec::new(),
            host: None,
            hosts: None,
            control_plane_first: false,
            deploy_jobs_per_domain: 8,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Selection {
    pub groups: Vec<String>,
    pub direct: Vec<String>,
    pub excluded: Vec<String>,
    pub dependency_excluded: Vec<String>,
    pub skipped: Vec<String>,
    pub ordered: Vec<String>,
    pub levels: Vec<Vec<String>>,
    pub waves: Vec<Vec<String>>,
}

pub fn select(inventory: &Inventory, options: &SelectionOptions) -> Result<Selection> {
    inventory.validate()?;
    if options.host.is_some() && options.hosts.is_some() {
        bail!("use either one exact host or host selectors, not both");
    }
    if options.deploy_jobs_per_domain == 0 {
        bail!("deploy jobs per domain must be positive");
    }

    let all_hosts = inventory.hosts.keys().cloned().collect::<Vec<_>>();
    let mut scope = all_hosts.clone();
    let mut dependency_excluded = BTreeSet::new();
    let groups = stable_unique(options.groups.iter().cloned());
    if !groups.is_empty() {
        scope.clear();
        let mut known_groups = BTreeSet::new();
        for host in inventory.hosts.values() {
            known_groups.extend(host.positive_groups().map(str::to_owned));
        }
        for group in &groups {
            if !known_groups.contains(group) {
                bail!("unknown group requested: {group}");
            }
            for (name, host) in &inventory.hosts {
                if host.positive_groups().any(|candidate| candidate == group)
                    && !scope.contains(name)
                {
                    scope.push(name.clone());
                }
                if host.negative_groups().any(|candidate| candidate == group) {
                    dependency_excluded.insert(name.clone());
                }
            }
        }
    }
    if scope.is_empty() {
        bail!("no hosts selected by groups");
    }

    let raw_selectors = options
        .host
        .as_deref()
        .or(options.hosts.as_deref())
        .unwrap_or("all");
    let (direct, excluded) = apply_selectors(&scope, raw_selectors)?;
    if direct.is_empty() {
        bail!("no hosts selected");
    }

    let direct_set = direct.iter().cloned().collect::<BTreeSet<_>>();
    let excluded_set = excluded.iter().cloned().collect::<BTreeSet<_>>();
    let mut expanded = expand_dependencies(inventory, &direct)?;
    expanded.retain(|host| {
        !excluded_set.contains(host)
            && (!dependency_excluded.contains(host) || direct_set.contains(host))
    });
    if expanded.is_empty() {
        bail!("no hosts selected after dependency exclusions");
    }
    validate_dependency_policies(inventory, &expanded)?;

    let control_plane = inventory.control_plane_hosts()?;
    let ordered_with_skips = topological_order(
        inventory,
        &expanded,
        options.control_plane_first,
        &control_plane,
    )?;
    let mut skipped = Vec::new();
    let mut ordered = Vec::new();
    for host in ordered_with_skips {
        if inventory.hosts[&host].skip {
            skipped.push(host);
        } else {
            ordered.push(host);
        }
    }
    if ordered.is_empty() {
        bail!("all selected hosts are skipped");
    }
    let levels = dependency_levels(inventory, &ordered, &control_plane)?;
    let waves = capacity_waves(inventory, &levels, options.deploy_jobs_per_domain)?;

    Ok(Selection {
        groups,
        direct,
        excluded,
        dependency_excluded: dependency_excluded.into_iter().collect(),
        skipped,
        ordered,
        levels,
        waves,
    })
}

fn apply_selectors(scope: &[String], raw: &str) -> Result<(Vec<String>, Vec<String>)> {
    let tokens = split_values(raw);
    if tokens.is_empty() {
        bail!("host selectors cannot be empty");
    }
    let has_positive = tokens.iter().any(|token| !token.starts_with('-'));
    let mut selected = if has_positive {
        Vec::new()
    } else {
        scope.to_vec()
    };
    let mut excluded = Vec::new();
    for token in tokens {
        let (exclude, pattern) = token
            .strip_prefix('-')
            .map_or((false, token.as_str()), |value| (true, value));
        if pattern.is_empty() {
            bail!("host exclusion cannot be empty");
        }
        let matching = if pattern == "all" {
            scope.to_vec()
        } else {
            scope
                .iter()
                .filter(|host| wildcard_match(pattern.as_bytes(), host.as_bytes()))
                .cloned()
                .collect::<Vec<_>>()
        };
        if matching.is_empty() {
            bail!("host selector {token:?} matched no hosts");
        }
        for host in matching {
            if exclude {
                if !excluded.contains(&host) {
                    excluded.push(host.clone());
                }
                selected.retain(|selected_host| selected_host != &host);
            } else if !selected.contains(&host) {
                selected.push(host);
            }
        }
    }
    Ok((selected, excluded))
}

fn expand_dependencies(inventory: &Inventory, direct: &[String]) -> Result<Vec<String>> {
    let mut queue = VecDeque::from(direct.to_vec());
    let mut seen = BTreeSet::new();
    let mut expanded = Vec::new();
    while let Some(name) = queue.pop_front() {
        if !inventory.hosts.contains_key(&name) {
            bail!("unknown host requested: {name}");
        }
        if !seen.insert(name.clone()) {
            continue;
        }
        expanded.push(name.clone());
        let host = &inventory.hosts[&name];
        for predecessor in host.deps.iter().chain(host.parent.iter()) {
            if !inventory.hosts.contains_key(predecessor) {
                bail!("unknown dependency declared for {name}: {predecessor}");
            }
            if !seen.contains(predecessor) {
                queue.push_back(predecessor.clone());
            }
        }
    }
    Ok(expanded)
}

fn validate_dependency_policies(inventory: &Inventory, selected: &[String]) -> Result<()> {
    let selected = selected.iter().collect::<BTreeSet<_>>();
    for name in &selected {
        let host = &inventory.hosts[*name];
        if host.skip {
            continue;
        }
        for dependency in host.deps.iter().chain(host.parent.iter()) {
            if !selected.contains(dependency) {
                continue;
            }
            let dependency_host = &inventory.hosts[dependency];
            if dependency_host.skip {
                bail!("host {name} cannot depend on skipped host {dependency}");
            }
            if dependency_host.deploy != DeployMode::Strict {
                bail!("host {name} cannot depend on non-strict deploy host {dependency}");
            }
        }
    }
    Ok(())
}

fn predecessors<'a>(inventory: &'a Inventory, name: &'a str) -> impl Iterator<Item = &'a String> {
    let host = &inventory.hosts[name];
    host.deps
        .iter()
        .chain(&host.after)
        .chain(host.parent.iter())
}

fn topological_order(
    inventory: &Inventory,
    selected: &[String],
    control_plane_first: bool,
    control_plane: &[String],
) -> Result<Vec<String>> {
    let selected_set = selected.iter().cloned().collect::<BTreeSet<_>>();
    let control_plane_set = control_plane.iter().cloned().collect::<BTreeSet<_>>();
    let mut indegree = BTreeMap::new();
    let mut dependents: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut edges = BTreeSet::new();
    for name in selected {
        indegree.insert(name.clone(), 0usize);
    }
    for name in selected {
        for predecessor in predecessors(inventory, name) {
            if selected_set.contains(predecessor) {
                *indegree.get_mut(name).expect("selected host has indegree") += 1;
                dependents
                    .entry(predecessor.clone())
                    .or_default()
                    .push(name.clone());
                edges.insert((predecessor.clone(), name.clone()));
            }
        }
    }
    if let Some(controller) = control_plane.first()
        && selected_set.contains(controller)
    {
        for registry in &control_plane[1..] {
            if selected_set.contains(registry)
                && edges.insert((controller.clone(), registry.clone()))
            {
                *indegree
                    .get_mut(registry)
                    .expect("selected registry has indegree") += 1;
                dependents
                    .entry(controller.clone())
                    .or_default()
                    .push(registry.clone());
            }
        }
    }

    let mut ordered = Vec::new();
    let mut emitted = BTreeSet::new();
    let mut control_plane_started = false;
    while ordered.len() < selected.len() {
        let mut progress = false;
        let prefer_control = control_plane_first || control_plane_started;
        for want_control in [prefer_control, !prefer_control] {
            loop {
                let mut class_progress = false;
                for name in selected {
                    if emitted.contains(name)
                        || indegree[name] != 0
                        || control_plane_set.contains(name) != want_control
                    {
                        continue;
                    }
                    emit_host(name, &mut ordered, &mut emitted, &mut indegree, &dependents);
                    control_plane_started |= want_control;
                    class_progress = true;
                    progress = true;
                }
                if !class_progress {
                    break;
                }
            }
            if progress {
                break;
            }
        }
        if !progress {
            let cycle = selected
                .iter()
                .filter(|name| !emitted.contains(*name))
                .cloned()
                .collect::<Vec<_>>();
            bail!("host dependency cycle detected among: {}", cycle.join(" "));
        }
    }
    Ok(ordered)
}

fn emit_host(
    name: &str,
    ordered: &mut Vec<String>,
    emitted: &mut BTreeSet<String>,
    indegree: &mut BTreeMap<String, usize>,
    dependents: &BTreeMap<String, Vec<String>>,
) {
    emitted.insert(name.to_owned());
    ordered.push(name.to_owned());
    for dependent in dependents.get(name).into_iter().flatten() {
        *indegree
            .get_mut(dependent)
            .expect("dependent host has indegree") -= 1;
    }
}

fn dependency_levels(
    inventory: &Inventory,
    ordered: &[String],
    control_plane: &[String],
) -> Result<Vec<Vec<String>>> {
    let selected = ordered.iter().cloned().collect::<BTreeSet<_>>();
    let control_plane_set = control_plane.iter().cloned().collect::<BTreeSet<_>>();
    let controller = control_plane.first();
    let mut host_levels = BTreeMap::<String, usize>::new();
    let mut active_control_class = None;
    let mut max_level = 0;
    let mut class_floor = 0;
    for name in ordered {
        let is_control = control_plane_set.contains(name);
        if active_control_class.is_some_and(|active| active != is_control) {
            class_floor = max_level + 1;
        }
        active_control_class = Some(is_control);
        let mut level = class_floor;
        for predecessor in predecessors(inventory, name) {
            if selected.contains(predecessor) {
                let predecessor_level = host_levels.get(predecessor).ok_or_else(|| {
                    anyhow::anyhow!("predecessor level missing for {name}: {predecessor}")
                })?;
                level = level.max(predecessor_level + 1);
            }
        }
        if is_control
            && controller.is_some_and(|controller| controller != name)
            && controller.is_some_and(|controller| selected.contains(controller))
        {
            let controller = controller.expect("checked controller exists");
            let controller_level = host_levels.get(controller).ok_or_else(|| {
                anyhow::anyhow!("controller level missing for registry host {name}")
            })?;
            level = level.max(controller_level + 1);
        }
        host_levels.insert(name.clone(), level);
        max_level = max_level.max(level);
    }
    let mut levels = vec![Vec::new(); max_level + 1];
    for name in ordered {
        levels[host_levels[name]].push(name.clone());
    }
    Ok(levels
        .into_iter()
        .filter(|level| !level.is_empty())
        .collect())
}

fn capacity_waves(
    inventory: &Inventory,
    levels: &[Vec<String>],
    per_domain: usize,
) -> Result<Vec<Vec<String>>> {
    let mut waves = Vec::new();
    for level in levels {
        let mut pending = level.clone();
        while !pending.is_empty() {
            let mut counts = BTreeMap::<String, usize>::new();
            let mut wave = Vec::new();
            let mut later = Vec::new();
            for host in pending {
                let domain = deploy_domain(inventory, &host)?;
                let count = counts.entry(domain).or_default();
                if *count >= per_domain {
                    later.push(host);
                } else {
                    *count += 1;
                    wave.push(host);
                }
            }
            if wave.is_empty() {
                bail!("deploy concurrency policy produced an empty wave");
            }
            waves.push(wave);
            pending = later;
        }
    }
    Ok(waves)
}

fn deploy_domain(inventory: &Inventory, name: &str) -> Result<String> {
    let mut current = name;
    let mut visited = BTreeSet::new();
    loop {
        if !visited.insert(current.to_owned()) {
            bail!("host parent cycle detected while resolving deploy domain for {name}: {current}");
        }
        match inventory.hosts[current].parent.as_deref() {
            Some(parent) => current = parent,
            None => return Ok(format!("parent:{current}")),
        }
    }
}

fn split_values(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\t', '\n'])
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

fn stable_unique(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .into_iter()
        .filter(|value| seen.insert(value.clone()))
        .collect()
}

fn wildcard_match(pattern: &[u8], value: &[u8]) -> bool {
    fn matches(
        pattern: &[u8],
        value: &[u8],
        pattern_index: usize,
        value_index: usize,
        memo: &mut BTreeMap<(usize, usize), bool>,
    ) -> bool {
        if let Some(result) = memo.get(&(pattern_index, value_index)) {
            return *result;
        }
        let result = match pattern.get(pattern_index).copied() {
            None => value_index == value.len(),
            Some(b'*') => {
                matches(pattern, value, pattern_index + 1, value_index, memo)
                    || (value_index < value.len()
                        && matches(pattern, value, pattern_index, value_index + 1, memo))
            }
            Some(b'?') => {
                value_index < value.len()
                    && matches(pattern, value, pattern_index + 1, value_index + 1, memo)
            }
            Some(b'[') if value_index < value.len() => {
                if let Some((end, class)) = parse_class(pattern, pattern_index) {
                    class.contains(value[value_index])
                        && matches(pattern, value, end + 1, value_index + 1, memo)
                } else {
                    value[value_index] == b'['
                        && matches(pattern, value, pattern_index + 1, value_index + 1, memo)
                }
            }
            Some(b'\\') if pattern_index + 1 < pattern.len() => {
                value.get(value_index) == pattern.get(pattern_index + 1)
                    && matches(pattern, value, pattern_index + 2, value_index + 1, memo)
            }
            Some(byte) => {
                value.get(value_index) == Some(&byte)
                    && matches(pattern, value, pattern_index + 1, value_index + 1, memo)
            }
        };
        memo.insert((pattern_index, value_index), result);
        result
    }

    #[derive(Clone, Debug)]
    struct Class {
        negated: bool,
        ranges: Vec<(u8, u8)>,
    }

    impl Class {
        fn contains(&self, byte: u8) -> bool {
            let member = self
                .ranges
                .iter()
                .any(|(start, end)| *start <= byte && byte <= *end);
            member != self.negated
        }
    }

    fn parse_class(pattern: &[u8], start: usize) -> Option<(usize, Class)> {
        let mut index = start + 1;
        let negated = matches!(pattern.get(index), Some(b'!' | b'^'));
        index += usize::from(negated);
        let mut bytes = Vec::new();
        if pattern.get(index) == Some(&b']') {
            bytes.push(b']');
            index += 1;
        }
        while index < pattern.len() && pattern[index] != b']' {
            if pattern[index] == b'\\' && index + 1 < pattern.len() {
                index += 1;
            }
            bytes.push(pattern[index]);
            index += 1;
        }
        if index == pattern.len() || bytes.is_empty() {
            return None;
        }
        let mut ranges = Vec::new();
        let mut member = 0;
        while member < bytes.len() {
            if member + 2 < bytes.len() && bytes[member + 1] == b'-' {
                let start = bytes[member];
                let end = bytes[member + 2];
                if start <= end {
                    ranges.push((start, end));
                } else {
                    ranges.push((start, start));
                    ranges.push((b'-', b'-'));
                    ranges.push((end, end));
                }
                member += 3;
            } else {
                ranges.push((bytes[member], bytes[member]));
                member += 1;
            }
        }
        Some((index, Class { negated, ranges }))
    }

    matches(pattern, value, 0, 0, &mut BTreeMap::new())
}
