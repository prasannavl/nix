use abird_host_manager::fleet::forced_command::{
    ARGUMENT_PREFIX, RequestSource, decode_arguments, encode_arguments, hydrate_arguments,
};

#[test]
fn nul_base64_codec_round_trips_arbitrary_non_nul_arguments() {
    let arguments = vec![
        "deploy".to_owned(),
        "--hosts".to_owned(),
        "one two,$HOME;'quoted'".to_owned(),
        String::new(),
        "line\nbreak".to_owned(),
    ];
    let encoded = encode_arguments(&arguments).unwrap();
    assert!(!encoded.contains('\n'));
    assert_eq!(decode_arguments(&encoded).unwrap(), arguments);
}

#[test]
fn explicit_encoded_argv_has_priority_over_original_command() {
    let encoded = encode_arguments(&["build", "--host", "app"]).unwrap();
    let hydrated = hydrate_arguments(
        &[ARGUMENT_PREFIX.to_owned(), encoded],
        Some("nixbot deploy --host ignored"),
    )
    .unwrap();
    assert_eq!(hydrated.arguments, ["build", "--host", "app"]);
    assert_eq!(hydrated.source, RequestSource::EncodedArguments);
}

#[test]
fn forced_command_accepts_encoded_or_restricted_simple_forms() {
    let encoded = encode_arguments(&["deploy", "--host", "app"]).unwrap();
    let request = hydrate_arguments(&[], Some(&format!("{ARGUMENT_PREFIX} {encoded}"))).unwrap();
    assert_eq!(request.arguments, ["deploy", "--host", "app"]);
    assert_eq!(request.source, RequestSource::ForcedCommandEncoded);

    let request = hydrate_arguments(&[], Some("-- nixbot build --hosts app,db")).unwrap();
    assert_eq!(request.arguments, ["build", "--hosts", "app,db"]);
    assert_eq!(request.source, RequestSource::ForcedCommandSimple);
}

#[test]
fn forced_simple_form_rejects_shell_syntax() {
    for command in [
        "nixbot deploy; id",
        "nixbot deploy $(id)",
        "nixbot deploy > /tmp/out",
        "nixbot deploy 'quoted'",
        "nixbot deploy\\ now",
    ] {
        assert!(
            hydrate_arguments(&[], Some(command))
                .unwrap_err()
                .to_string()
                .contains("unsupported SSH forced-command syntax"),
            "command unexpectedly accepted: {command}"
        );
    }
}

#[test]
fn malformed_encoded_payloads_fail_closed() {
    for arguments in [
        vec![ARGUMENT_PREFIX.to_owned()],
        vec![ARGUMENT_PREFIX.to_owned(), "%%%".to_owned()],
        vec![
            ARGUMENT_PREFIX.to_owned(),
            encode_arguments(&["has\0nul"]).unwrap_err().to_string(),
        ],
    ] {
        assert!(hydrate_arguments(&arguments, None).is_err());
    }
    assert!(hydrate_arguments(&[], Some(ARGUMENT_PREFIX)).is_err());
}

#[test]
fn ordinary_local_arguments_are_unchanged() {
    let request = hydrate_arguments(&["build".to_owned(), "--host=app".to_owned()], None).unwrap();
    assert_eq!(request.arguments, ["build", "--host=app"]);
    assert_eq!(request.source, RequestSource::LocalArguments);
}
