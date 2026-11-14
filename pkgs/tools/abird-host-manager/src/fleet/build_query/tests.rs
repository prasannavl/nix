use super::*;

#[test]
fn admitted_attribute_paths_preserve_empty_components_and_native_prefix_order() {
    assert_eq!(parse_path("a..b."), ["a", "", "b"]);
    assert_eq!(parse_path("..."), ["", "", ""]);
    assert!(parse_path("").is_empty());
    assert_eq!(
        candidates("value", "x86_64-linux"),
        [
            vec!["packages", "x86_64-linux", "value"],
            vec!["legacyPackages", "x86_64-linux", "value"],
            vec!["value"],
        ]
    );
    assert_eq!(candidates(".value", "x86_64-linux"), [vec!["value"]]);
    assert_eq!(candidates("..value", "x86_64-linux"), [vec!["", "value"]]);
}

#[test]
fn shared_query_description_preserves_legacy_argv() {
    let arguments = vec!["--store".into(), "daemon".into()];
    let command = FlakeQuery::catalog().command("nix", &arguments, ".");
    assert_eq!(
        command.args,
        [
            "eval",
            "--store",
            "daemon",
            "--json",
            "--no-write-lock-file",
            ".#nixbot.plans",
            "--apply",
            "builtins.attrNames"
        ]
    );
    let command = FlakeQuery::derivation(BuildPlanAttribute::NixosConfiguration, "host")
        .command("nix", &arguments, ".");
    assert_eq!(
        command.args,
        [
            "eval",
            "--store",
            "daemon",
            "--raw",
            "--no-write-lock-file",
            ".#nixosConfigurations.host.config.system.build.toplevel.drvPath"
        ]
    );
}

#[test]
fn upstream_selection_is_one_output_query_without_a_provenance_claim() {
    let reference = "git+file:///original/run/repo?dir=relative&narHash=sha256-value";
    let command = FlakeQuery::catalog()
        .selection_command("/installed/nix", &[], reference, "aarch64-linux")
        .unwrap();
    assert_eq!(command.program, "/installed/nix");
    let installables = command
        .args
        .iter()
        .filter(|arg| arg.contains('#'))
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(installables, [format!("{reference}#.")]);
    assert!(
        command
            .args
            .windows(3)
            .any(|args| args == ["--option", "system", "aarch64-linux"])
    );
    assert!(
        !command.args.iter().any(|arg| arg.contains("--abird-owned")
            || arg.contains("getFlake")
            || arg == "--expr")
    );
    let expression = command.args.last().unwrap();
    assert!(expression.contains("builtins.filter"));
    assert!(!expression.contains("sourceInfo"));
    assert!(expression.contains("legacyPackages.aarch64-linux.nixbot.plans"));
    assert!(!expression.contains("tryEval"));
}

#[test]
fn unsupported_uri_quoted_or_code_selectors_reject_without_reinterpretation() {
    for attribute in [
        "",
        "a%2Eb",
        "a^out",
        "a#other",
        "a.\"literal.dot\"",
        "a\\b",
        "${throw \"not-code\"}",
        "broken\nname",
        "日本語",
    ] {
        assert!(
            FlakeQuery::value(attribute)
                .selection_command("nix", &[], "git+file:///source", "x86_64-linux")
                .is_err()
        );
    }
    let query = FlakeQuery::value("nixbot.deployDependencies");
    assert!(
        query
            .selection_command("nix", &[], "git+file:///source#other", "x86_64-linux")
            .is_err()
    );
    assert!(
        query
            .selection_command("nix", &[], "git+file:///source", "")
            .is_err()
    );
}

#[test]
fn selection_distinguishes_native_absence_from_failure_or_null() {
    use serde_json::{from_value, json};
    let mut value = json!({"version": 1, "system": "x86_64-linux",
        "present": false, "attribute": null, "result": null});
    let selected: Selection = from_value(value.clone()).unwrap();
    selected.validate(true, "x86_64-linux").unwrap();
    assert!(selected.validate(false, "x86_64-linux").is_err());
    assert!(selected.validate(true, "aarch64-linux").is_err());
    value["present"] = json!(true);
    assert!(
        from_value::<Selection>(value.clone())
            .unwrap()
            .validate(true, "x86_64-linux")
            .is_err()
    );
    value["attribute"] = json!("nixbot.plans");
    assert!(
        from_value::<Selection>(value.clone())
            .unwrap()
            .validate(true, "x86_64-linux")
            .is_err()
    );
    value["result"] = json!([]);
    from_value::<Selection>(value.clone())
        .unwrap()
        .validate(true, "x86_64-linux")
        .unwrap();
    value.as_object_mut().unwrap().remove("attribute");
    assert!(from_value::<Selection>(value).is_err());
}

#[test]
fn output_metadata_and_old_envelopes_cannot_be_promoted_to_source_evidence() {
    use serde_json::{from_value, json};
    let mut value = json!({"version": 1, "system": "x86_64-linux",
        "present": true, "attribute": "metadata", "result": {"sourceInfo": "ordinary data"}});
    from_value::<Selection>(value.clone())
        .unwrap()
        .validate(false, "x86_64-linux")
        .unwrap();
    value["sourceInfo"] = json!({"outPath": "/nix/store/00000000000000000000000000000000-forged"});
    assert!(from_value::<Selection>(value.clone()).is_err());
    value["version"] = json!(2);
    assert!(from_value::<Selection>(value.clone()).is_err());
    value.as_object_mut().unwrap().remove("sourceInfo");
    assert!(
        from_value::<Selection>(value)
            .unwrap()
            .validate(false, "x86_64-linux")
            .is_err()
    );
}
