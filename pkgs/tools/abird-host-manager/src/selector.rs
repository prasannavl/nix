use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, bail};

use crate::agent_adapter::Host;

pub fn select_hosts<'a>(
    hosts: &'a BTreeMap<String, Host>,
    group: Option<&str>,
    selectors: Option<&str>,
) -> Result<Vec<&'a str>> {
    let eligible = hosts
        .iter()
        .filter(|(_, host)| group.is_none_or(|group| host.groups.contains(group)))
        .map(|(name, _)| name.as_str())
        .collect::<Vec<_>>();

    if eligible.is_empty() {
        if let Some(group) = group {
            bail!("inventory group {group:?} contains no hosts");
        }
        bail!("manager inventory contains no selectable hosts");
    }

    let Some(selectors) = selectors else {
        return Ok(eligible);
    };
    let tokens = selectors
        .split([',', ' ', '\t', '\n'])
        .filter(|token| !token.is_empty())
        .collect::<Vec<_>>();
    if tokens.is_empty() {
        bail!("host selectors cannot be empty");
    }

    let has_inclusion = tokens.iter().any(|token| !token.starts_with('-'));
    let mut selected = if has_inclusion {
        BTreeSet::new()
    } else {
        eligible.iter().copied().collect()
    };

    for token in tokens {
        let (exclude, pattern) = match token.strip_prefix('-') {
            Some(pattern) => (true, pattern),
            None => (false, token),
        };
        if pattern.is_empty() {
            bail!("host exclusion cannot be empty");
        }
        let matches = if pattern == "all" {
            eligible.clone()
        } else {
            eligible
                .iter()
                .copied()
                .filter(|name| wildcard_match(pattern.as_bytes(), name.as_bytes()))
                .collect::<Vec<_>>()
        };
        if matches.is_empty() {
            bail!("host selector {token:?} matched no hosts");
        }
        for name in matches {
            if exclude {
                selected.remove(name);
            } else {
                selected.insert(name);
            }
        }
    }

    if selected.is_empty() {
        bail!("host selection is empty after applying exclusions");
    }
    Ok(selected.into_iter().collect())
}

fn wildcard_match(pattern: &[u8], value: &[u8]) -> bool {
    let (mut pattern_index, mut value_index) = (0, 0);
    let mut star = None;
    let mut retry_value = 0;

    while value_index < value.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == b'?' || pattern[pattern_index] == value[value_index])
        {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star = Some(pattern_index);
            pattern_index += 1;
            retry_value = value_index;
        } else if let Some(star_index) = star {
            pattern_index = star_index + 1;
            retry_value += 1;
            value_index = retry_value;
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(groups: &[&str]) -> Host {
        Host {
            address: "127.0.0.1".to_owned(),
            local: false,
            user: None,
            port: None,
            identity_file: None,
            operator_user: None,
            operator_identity_file: None,
            operator_port: None,
            known_hosts_file: None,
            host_key_alias: None,
            host_key_check: None,
            ssh_args: Vec::new(),
            proxy_jump: None,
            proxy_command: None,
            broker_ssh_args: Vec::new(),
            agent_program: "/bin/agent".into(),
            agent_prefix: Vec::new(),
            host_resource: None,
            groups: groups.iter().map(|value| (*value).to_owned()).collect(),
            nixbot_deploy: None,
            rsync_program: "/bin/rsync".into(),
            rsync_prefix: None,
            tar_program: "/bin/tar".into(),
        }
    }

    #[test]
    fn supports_groups_globs_and_exclusions() {
        let hosts = BTreeMap::from([
            ("abird-corp".to_owned(), host(&["prod", "abird"])),
            ("abird-zulip".to_owned(), host(&["prod", "abird"])),
            ("pvl-a1".to_owned(), host(&["personal"])),
        ]);
        assert_eq!(
            select_hosts(&hosts, Some("abird"), Some("abird-*,-*corp")).unwrap(),
            ["abird-zulip"]
        );
        assert_eq!(
            select_hosts(&hosts, Some("prod"), Some("-*zulip")).unwrap(),
            ["abird-corp"]
        );
    }

    #[test]
    fn fails_closed_for_typos_and_empty_results() {
        let hosts = BTreeMap::from([("abird-corp".to_owned(), host(&["prod"]))]);
        assert!(select_hosts(&hosts, None, Some("missing*")).is_err());
        assert!(select_hosts(&hosts, None, Some("all,-all")).is_err());
        assert!(select_hosts(&hosts, Some("stage"), None).is_err());
    }
}
