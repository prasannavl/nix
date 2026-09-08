use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use abird_host_manager::fleet::cli::Options;
use abird_host_manager::fleet::inventory::{DeployConfig, Host, HostDefaults, Inventory};
use abird_host_manager::fleet::system::{ResolvedHost, resolve_host};

fn inventory() -> Inventory {
    Inventory {
        hosts: BTreeMap::from([
            (
                "jump".to_owned(),
                Host {
                    target: Some("jump.example".to_owned()),
                    operator_user: Some("operator".to_owned()),
                    operator_key: Some(PathBuf::from("keys/operator.age")),
                    ..Host::default()
                },
            ),
            (
                "app".to_owned(),
                Host {
                    target: Some("10.0.0.2".to_owned()),
                    port: Some(2222),
                    proxy_jump: Some("jump".to_owned()),
                    bootstrap_port: Some(2200),
                    age_identity_key: Some(PathBuf::from("keys/app-machine.age")),
                    resource_id: Some("app-resource".to_owned()),
                    ..Host::default()
                },
            ),
        ]),
        config: DeployConfig {
            host_defaults: HostDefaults {
                user: Some("nixbot".to_owned()),
                identity_key: Some(PathBuf::from("keys/nixbot.age")),
                known_hosts: Some("known-host-line".to_owned()),
                operator_user: Some("root".to_owned()),
                operator_key: Some(PathBuf::from("keys/root.age")),
                bootstrap_key: Some(PathBuf::from("keys/bootstrap.age")),
                bootstrap_port: Some(22),
                ..HostDefaults::default()
            },
            ..DeployConfig::default()
        },
    }
}

#[test]
fn host_resolution_applies_exact_inventory_fallback_order() {
    let resolved = resolve_host(&inventory(), "app", &Options::default()).unwrap();
    assert_eq!(
        resolved,
        ResolvedHost {
            inventory_name: "app".to_owned(),
            resource: "app-resource".to_owned(),
            target: "10.0.0.2".to_owned(),
            user: "nixbot".to_owned(),
            port: 2222,
            identity_key: Some(PathBuf::from("keys/nixbot.age")),
            known_hosts: Some("known-host-line".to_owned()),
            bootstrap_key: Some(PathBuf::from("keys/bootstrap.age")),
            operator_user: Some("root".to_owned()),
            operator_port: 2200,
            operator_key: Some(PathBuf::from("keys/root.age")),
            age_identity_key: Some(PathBuf::from("keys/app-machine.age")),
            proxy_jump: Some("jump".to_owned()),
            proxy_command: None,
        }
    );
}

#[test]
fn user_overrides_clear_inherited_identity_unless_identity_is_also_overridden() {
    let mut options = Options {
        user: Some("root".to_owned()),
        ..Options::default()
    };
    let resolved = resolve_host(&inventory(), "app", &options).unwrap();
    assert_eq!(resolved.user, "root");
    assert_eq!(resolved.identity_key, None);

    options.ssh_key = Some(PathBuf::from("/tmp/explicit-key"));
    let resolved = resolve_host(&inventory(), "app", &options).unwrap();
    assert_eq!(
        resolved.identity_key.as_deref(),
        Some(Path::new("/tmp/explicit-key"))
    );
}

#[test]
fn operator_overrides_clear_only_operator_identity_and_unknown_roles_fail() {
    let options = Options {
        operator_user: Some("admin".to_owned()),
        ..Options::default()
    };
    let resolved = resolve_host(&inventory(), "app", &options).unwrap();
    assert_eq!(resolved.operator_user.as_deref(), Some("admin"));
    assert_eq!(resolved.operator_key, None);
    assert!(resolve_host(&inventory(), "missing", &options).is_err());
}
