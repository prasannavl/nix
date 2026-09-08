use std::collections::BTreeMap;
use std::path::PathBuf;

use abird_host_manager::fleet::transport::{
    BuildLocation, CacheEndpoint, CacheFallback, CacheTransferPolicy, DistributionInput,
    DistributionPlan, FailureClass, FailureEvidence, HostKeyPolicy, HostTransport, ProcessStatus,
    ProxyCommandTemplate, RetryDecision, RetryPolicy, RetryScope, SelfTargetDecision,
    SelfTargetEvidence, SelfTargetMode, SelfTargetRemoteReason, SshEndpoint, SshRoutePlan,
    TransportRole, plan_cache_distribution, plan_proxy_chain, plan_self_target,
};

fn endpoint(node: &str, role: TransportRole) -> SshEndpoint {
    SshEndpoint::new(
        node,
        format!("{node}.internal"),
        "nixbot",
        22,
        role,
        Some(PathBuf::from(format!("/keys/{node}"))),
    )
    .unwrap()
}

fn host(node: &str, proxy_jump: Option<&str>, local: bool) -> HostTransport {
    HostTransport {
        primary: endpoint(node, TransportRole::Primary),
        operator: None,
        proxy_jump: proxy_jump.map(str::to_owned),
        proxy_command: None,
        local,
    }
}

#[test]
fn proxy_chain_is_outermost_first_and_prefers_operator_endpoints() {
    let mut hosts = BTreeMap::from([
        ("controller".to_owned(), host("controller", None, true)),
        ("edge".to_owned(), host("edge", Some("controller"), false)),
        ("inner".to_owned(), host("inner", Some("edge"), true)),
    ]);
    hosts.get_mut("edge").unwrap().operator = Some(
        SshEndpoint::new(
            "edge",
            "edge-operator.internal",
            "operator",
            2202,
            TransportRole::Operator,
            Some(PathBuf::from("/keys/edge-operator")),
        )
        .unwrap(),
    );
    hosts.get_mut("edge").unwrap().proxy_command =
        Some(ProxyCommandTemplate::new("connect --host %h --port %p --literal %%").unwrap());
    assert_eq!(
        hosts
            .get("edge")
            .unwrap()
            .proxy_command
            .as_ref()
            .unwrap()
            .as_str(),
        "connect --host %h --port %p --literal %%"
    );

    let full = plan_proxy_chain(&hosts, Some("inner")).unwrap();
    assert_eq!(
        full.hops
            .iter()
            .map(|hop| hop.node.as_str())
            .collect::<Vec<_>>(),
        ["controller", "edge", "inner"]
    );
    assert_eq!(full.hops[1].endpoint.role, TransportRole::Operator);
    assert_eq!(full.hops[1].endpoint.user, "operator");
    assert_eq!(
        full.hops[1]
            .proxy_command
            .as_ref()
            .unwrap()
            .render("service.internal", 2222),
        "connect --host service.internal --port 2222 --literal %%"
    );

    let effective = full.with_leading_local_hops_trimmed();
    assert_eq!(
        effective
            .hops
            .iter()
            .map(|hop| hop.node.as_str())
            .collect::<Vec<_>>(),
        ["edge", "inner"]
    );
    assert!(
        effective.hops[1].local,
        "non-leading local hops are retained"
    );
}

#[test]
fn proxy_chain_rejects_cycles_and_unknown_hops() {
    let cycle = BTreeMap::from([
        ("a".to_owned(), host("a", Some("b"), false)),
        ("b".to_owned(), host("b", Some("a"), false)),
    ]);
    let error = plan_proxy_chain(&cycle, Some("a")).unwrap_err().to_string();
    assert!(error.contains("a -> b -> a"), "{error}");

    let unknown = BTreeMap::from([("a".to_owned(), host("a", Some("missing"), false))]);
    let error = plan_proxy_chain(&unknown, Some("a"))
        .unwrap_err()
        .to_string();
    assert!(error.contains("unknown proxy hop missing"), "{error}");

    let mut invalid_role = host("a", None, false);
    invalid_role.operator = Some(endpoint("a", TransportRole::Primary));
    let error = plan_proxy_chain(&BTreeMap::from([("a".to_owned(), invalid_role)]), Some("a"))
        .unwrap_err()
        .to_string();
    assert!(
        error.contains("operator endpoint must use operator role"),
        "{error}"
    );
}

#[test]
fn ssh_routes_encode_role_address_and_trust_policy() {
    let primary = endpoint("app", TransportRole::Primary);
    assert_eq!(primary.connect_target(), "nixbot@app.internal");
    assert_eq!(primary.forward_destination(), "app.internal:22");

    let ipv6 = SshEndpoint::new(
        "app-v6",
        "2001:db8::10",
        "operator",
        2200,
        TransportRole::Operator,
        None,
    )
    .unwrap();
    assert_eq!(ipv6.forward_destination(), "[2001:db8::10]:2200");

    let direct = SshRoutePlan::direct(primary.clone());
    assert_eq!(direct.host_key_policy, HostKeyPolicy::Strict);
    let proxied = SshRoutePlan::via_chain(
        primary,
        plan_proxy_chain(
            &BTreeMap::from([("jump".to_owned(), host("jump", None, false))]),
            Some("jump"),
        )
        .unwrap(),
    );
    assert_eq!(proxied.host_key_policy, HostKeyPolicy::AcceptNew);

    let command = ProxyCommandTemplate::new("tunnel %h %p").unwrap();
    let via_command = SshRoutePlan::via_command(ipv6, command.clone());
    assert_eq!(via_command.host_key_policy, HostKeyPolicy::AcceptNew);
    assert_eq!(via_command.proxy_command, Some(command));
}

#[test]
fn retry_classification_preserves_signals_and_host_key_permanence() {
    let policy = RetryPolicy::new(3, 2).unwrap();

    let signal = FailureEvidence::new(
        ProcessStatus::Signal(2),
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
    );
    assert_eq!(signal.classify(), FailureClass::Signal(2));
    assert_eq!(
        policy.decide(&signal, RetryScope::Transport, 1),
        RetryDecision::Stop(FailureClass::Signal(2))
    );

    let changed_key = FailureEvidence::new(
        ProcessStatus::Code(255),
        "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
    );
    assert_eq!(changed_key.classify(), FailureClass::HostKeyVerification);
    assert_eq!(
        policy.decide(&changed_key, RetryScope::Transport, 1),
        RetryDecision::Stop(FailureClass::HostKeyVerification)
    );

    let disconnected = FailureEvidence::new(ProcessStatus::Code(255), "");
    assert_eq!(
        policy.decide(&disconnected, RetryScope::Transport, 1),
        RetryDecision::RetryAfter {
            next_attempt: 2,
            delay_seconds: 2,
            failure: FailureClass::TransportLoss,
        }
    );
    assert_eq!(
        policy.decide(&disconnected, RetryScope::Transport, 3),
        RetryDecision::Stop(FailureClass::TransportLoss)
    );
}

#[test]
fn retry_scope_is_narrow_but_remote_store_recognizes_daemon_loss() {
    let policy = RetryPolicy::new(4, 3).unwrap();
    let broken_pipe = FailureEvidence::new(ProcessStatus::Code(1), "Broken pipe");
    assert_eq!(broken_pipe.classify(), FailureClass::TransportLoss);
    assert_eq!(
        policy.decide(&broken_pipe, RetryScope::Transport, 1),
        RetryDecision::Stop(FailureClass::TransportLoss)
    );
    assert!(matches!(
        policy.decide(&broken_pipe, RetryScope::RemoteStore, 1),
        RetryDecision::RetryAfter { .. }
    ));

    let daemon = FailureEvidence::new(
        ProcessStatus::Code(1),
        "error: Nix daemon disconnected unexpectedly",
    );
    assert_eq!(daemon.classify(), FailureClass::DaemonDisconnected);
    assert_eq!(
        policy.decide(&daemon, RetryScope::RemoteStore, 2),
        RetryDecision::RetryAfter {
            next_attempt: 3,
            delay_seconds: 6,
            failure: FailureClass::DaemonDisconnected,
        }
    );
}

#[test]
fn pre_admission_classification_excludes_signals_and_changed_host_keys() {
    let refused = FailureEvidence::new(
        ProcessStatus::Code(255),
        "ssh: connect to host app port 22: Connection refused",
    );
    assert!(refused.is_pre_admission_ssh_failure());

    let changed_key = FailureEvidence::new(
        ProcessStatus::Code(255),
        "Offending ED25519 key in /tmp/known_hosts:1",
    );
    assert!(!changed_key.is_pre_admission_ssh_failure());

    let signal = FailureEvidence::new(
        ProcessStatus::Signal(15),
        "Connection timed out during banner exchange",
    );
    assert!(!signal.is_pre_admission_ssh_failure());
}

#[test]
fn self_target_requires_both_a_match_and_local_user_authority() {
    let matching = SelfTargetEvidence {
        alias_matches: false,
        address_matches: true,
        effective_uid: 1000,
        current_user: "nixbot".to_owned(),
        deploy_user: "nixbot".to_owned(),
    };
    assert_eq!(
        plan_self_target(SelfTargetMode::Auto, &matching),
        SelfTargetDecision::Local
    );
    assert_eq!(
        plan_self_target(SelfTargetMode::Off, &matching),
        SelfTargetDecision::Remote(SelfTargetRemoteReason::Disabled)
    );

    let unauthorized = SelfTargetEvidence {
        current_user: "alice".to_owned(),
        ..matching.clone()
    };
    assert_eq!(
        plan_self_target(SelfTargetMode::On, &unauthorized),
        SelfTargetDecision::Remote(SelfTargetRemoteReason::UnauthorizedUser)
    );

    let root = SelfTargetEvidence {
        effective_uid: 0,
        current_user: "root".to_owned(),
        ..matching
    };
    assert_eq!(
        plan_self_target(SelfTargetMode::On, &root),
        SelfTargetDecision::Local
    );
}

fn distribution_input(mode: CacheTransferPolicy) -> DistributionInput {
    DistributionInput {
        mode,
        build: BuildLocation::Remote {
            resource: "builder-resource".to_owned(),
        },
        target_resource: "target-resource".to_owned(),
        target_is_local: false,
        cache: Some(CacheEndpoint {
            owner_resource: "builder-resource".to_owned(),
            url: "https://cache.internal".to_owned(),
        }),
    }
}

#[test]
fn cache_distribution_respects_store_identity_and_explicit_modes() {
    let mut same_store = distribution_input(CacheTransferPolicy::Auto);
    same_store.target_resource = "builder-resource".to_owned();
    assert_eq!(
        plan_cache_distribution(&same_store).unwrap(),
        DistributionPlan::SameStoreVerify
    );

    let mut local = distribution_input(CacheTransferPolicy::Auto);
    local.build = BuildLocation::Local;
    local.cache = None;
    assert_eq!(
        plan_cache_distribution(&local).unwrap(),
        DistributionPlan::LocalCopy
    );

    let explicit_cache = distribution_input(CacheTransferPolicy::Cache);
    assert_eq!(
        plan_cache_distribution(&explicit_cache).unwrap(),
        DistributionPlan::TargetCache {
            cache: explicit_cache.cache.unwrap(),
            retry_transport: true,
            fallback: None,
        }
    );

    let local_relay = distribution_input(CacheTransferPolicy::LocalCopy);
    assert_eq!(
        plan_cache_distribution(&local_relay).unwrap(),
        DistributionPlan::LocalRelay {
            cache: local_relay.cache.unwrap(),
        }
    );
}

#[test]
fn automatic_cache_copy_falls_back_only_for_remote_nonsignal_failures() {
    let automatic = distribution_input(CacheTransferPolicy::Auto);
    let plan = plan_cache_distribution(&automatic).unwrap();
    let DistributionPlan::TargetCache {
        retry_transport,
        fallback,
        ..
    } = &plan
    else {
        panic!("expected target cache plan");
    };
    assert!(!retry_transport);
    assert_eq!(*fallback, Some(CacheFallback::LocalRelay));
    assert_eq!(
        plan.fallback_after(&FailureClass::Permanent),
        Some(CacheFallback::LocalRelay)
    );
    assert_eq!(
        plan.fallback_after(&FailureClass::Signal(15)),
        None,
        "signals must never be converted into cache fallback"
    );

    let mut local_target = automatic;
    local_target.target_is_local = true;
    let plan = plan_cache_distribution(&local_target).unwrap();
    assert_eq!(plan.fallback_after(&FailureClass::Permanent), None);
}

#[test]
fn remote_distribution_requires_a_cache_owned_by_the_builder() {
    let mut input = distribution_input(CacheTransferPolicy::Auto);
    input.cache.as_mut().unwrap().owner_resource = "other-resource".to_owned();
    let error = plan_cache_distribution(&input).unwrap_err().to_string();
    assert!(
        error.contains("not owned by remote build resource"),
        "{error}"
    );

    input.cache = None;
    let error = plan_cache_distribution(&input).unwrap_err().to_string();
    assert!(error.contains("requires a configured cache"), "{error}");
}
