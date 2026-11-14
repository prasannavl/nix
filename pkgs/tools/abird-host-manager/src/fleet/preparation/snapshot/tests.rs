use super::*;
use serde_json::json;

fn snapshot(name: &str, digit: char) -> NarSnapshot {
    NarSnapshot::new(
        format!("/nix/store/{}-{name}", "a".repeat(32)),
        &digit.to_string().repeat(64),
    )
    .unwrap()
}
fn commands() -> InventoryCommands {
    let tree = snapshot("source", 'a');
    InventoryCommands::new(
        Path::new("/nix/store/nix/bin/nix"),
        &tree.location("hosts/inventory.nix").unwrap(),
        Some(&tree.location("operator.nix").unwrap()),
        Some(&tree.location("config").unwrap()),
    )
    .unwrap()
}

#[test]
fn snapshot_rejects_non_store_roots_and_noncanonical_digests() {
    for path in [
        "relative",
        "/nix/store",
        "/nix/store/not-a-root",
        "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source/subdir",
    ] {
        assert!(NarSnapshot::new(path.into(), &"a".repeat(64)).is_err());
    }
    for hash in ["a".repeat(63), "A".repeat(64), "z".repeat(64)] {
        assert!(NarSnapshot::new(snapshot("source", 'a').path, &hash).is_err());
    }
}

#[test]
fn snapshot_locations_reject_escape_and_ambiguous_components() {
    let tree = snapshot("source", 'a');
    for path in [
        "/outside",
        "../file",
        "x/../file",
        "x/./file",
        "x//file",
        "x/",
        "line\nbreak",
    ] {
        assert!(tree.location(path).is_err(), "{path:?}");
    }
    assert!(tree.location("").is_ok());
    assert!(
        InventoryCommands::new(Path::new("/nix"), &tree.location("").unwrap(), None, None).is_err()
    );
    assert!(
        InventoryCommands::new(
            Path::new("nix"),
            &tree.location("inventory.nix").unwrap(),
            None,
            None
        )
        .is_err()
    );
}

#[test]
fn exact_hash_uri_and_nix_literals_do_not_become_code_or_broad_prefixes() {
    let tree = snapshot("source?x=y+z", 'f');
    assert!(
        tree.allowed_uri()
            .contains("source%3Fx%3Dy%2Bz?narHash=sha256-")
    );
    assert!(tree.allowed_uri().ends_with("%3D"));
    let input = tree.location("${throw \"not interpolation\"}.nix").unwrap();
    assert!(
        input
            .expression()
            .contains("\\${throw \\\"not interpolation\\\"}")
    );
    assert_eq!(literal("\\${x}"), "\"\\\\\\${x}\"");
}

#[test]
fn inventory_commands_are_pure_daemon_bound_and_allow_only_used_exact_snapshots() {
    let tree = snapshot("source", 'a');
    let config = snapshot("config", 'b');
    let commands = InventoryCommands::new(
        Path::new("/nix"),
        &tree.location("inventory.nix").unwrap(),
        None,
        Some(&config.location("").unwrap()),
    )
    .unwrap();
    assert!(commands.overlay.is_none());
    let args = &commands.base.args;
    assert_eq!(&args[..4], ["--store", "daemon", "eval", "--json"]);
    for option in [
        ["pure-eval", "true"],
        ["restrict-eval", "true"],
        ["allow-import-from-derivation", "false"],
    ] {
        assert!(args.windows(2).any(|pair| pair == option));
    }
    let index = args.iter().position(|arg| arg == "allowed-uris").unwrap();
    let expected = BTreeSet::from([tree.allowed_uri(), config.allowed_uri()]);
    assert_eq!(
        args[index + 1]
            .split(' ')
            .map(str::to_owned)
            .collect::<BTreeSet<_>>(),
        expected
    );
    assert!(!args.iter().any(|arg| arg == "--impure"));
    assert!(args.last().unwrap().contains("stacks = (import"));
}

#[test]
fn native_inventory_uses_the_exact_cli_expressions_and_allowlist_without_argv_reparsing() {
    let tree = snapshot("source", 'a');
    let config = snapshot("config", 'b');
    let base = tree.location("inventory.nix").unwrap();
    let overlay = tree.location("overlay.nix").unwrap();
    let config = config.location("").unwrap();
    let expressions = InventoryExpressions::new(&base, Some(&overlay), Some(&config)).unwrap();
    let commands =
        InventoryCommands::new(Path::new("/nix"), &base, Some(&overlay), Some(&config)).unwrap();
    for (expression, command) in [
        (&expressions.base, &commands.base),
        (
            expressions.overlay.as_ref().unwrap(),
            commands.overlay.as_ref().unwrap(),
        ),
    ] {
        assert_eq!(command.args.last().unwrap(), &expression.expression);
        let at = command
            .args
            .iter()
            .position(|arg| arg == "allowed-uris")
            .unwrap();
        assert_eq!(
            command.args[at + 1],
            expression
                .allowed_uris
                .iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    let mut calls = 0;
    let (merged, base, overlay) = expressions
        .evaluate(|_| {
            calls += 1;
            Ok(if calls == 1 {
                json!({"value":"base", "keep":true})
            } else {
                json!({"value":"overlay"})
            })
        })
        .unwrap();
    assert_eq!(calls, 2);
    assert_eq!(merged, json!({"value":"overlay", "keep":true}));
    assert_eq!(base["value"], "base");
    assert_eq!(overlay.unwrap()["value"], "overlay");
}

#[test]
fn native_function_application_and_route_layer_replacement_are_reused() {
    let commands = commands();
    let base = json!({"hosts":{"app":{"routes":{"cf":{"target":"base","proxyCommand":"remove"}}}}});
    let overlay = json!({"hosts":{"app":{"routes":{"cf":{"target":"operator"}}}}});
    let mut count = 0;
    let (merged, original, actual_overlay) = commands
        .evaluate(|_| {
            count += 1;
            Ok(if count == 1 {
                base.clone()
            } else {
                overlay.clone()
            })
        })
        .unwrap();
    assert_eq!(count, 2);
    assert_eq!(original, base);
    assert_eq!(actual_overlay, Some(overlay));
    assert_eq!(
        merged["hosts"]["app"]["routes"]["cf"],
        json!({"target":"operator"})
    );
    assert!(
        commands
            .base
            .args
            .last()
            .unwrap()
            .contains("builtins.isFunction inventory")
    );
}

#[test]
fn absent_overlay_is_not_discovered_and_failed_layers_never_return_partial_inventory() {
    let tree = snapshot("source", 'a');
    let only = InventoryCommands::new(
        Path::new("/nix"),
        &tree.location("inventory.nix").unwrap(),
        None,
        None,
    )
    .unwrap();
    let mut count = 0;
    assert_eq!(
        only.evaluate(|_| {
            count += 1;
            Ok(json!({}))
        })
        .unwrap()
        .2,
        None
    );
    assert_eq!(count, 1);
    assert!(!only.base.args.last().unwrap().contains("stacks ="));
    for failed_call in [1, 2] {
        let mut count = 0;
        assert!(
            commands()
                .evaluate(|_| {
                    count += 1;
                    if count == failed_call {
                        anyhow::bail!("bounded executor failed");
                    }
                    Ok(json!({}))
                })
                .is_err()
        );
        assert_eq!(count, failed_call);
    }
}
